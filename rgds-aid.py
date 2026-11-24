#!/usr/bin/env python3
"""rgds-aid: chat sidecar. Game <-> localhost TCP (NDJSON) <-> opencode serve.

Python stdlib only. OpenCode owns the model config under /userdata/opencode/.
This process does not read /userdata/rgds-ai/config.json.

  RGDS_OPENCODE_URL              default http://127.0.0.1:4096
  RGDS_OPENCODE_WORKDIR          default /mnt/mmc/Roms/APPS/RGDS-Agents
  RGDS_OPENCODE_PASSWORD_FILE    default /userdata/opencode/server.password
  OPENCODE_PASSWORD              overrides the password file
  RGDS_AI_PORT                   default 7788

The password is sent only as HTTP Basic user "opencode". It is never written
to the log or to a protocol message.

Game -> aid:  {"op":"chat","id","text"} {"op":"cancel","id"}
              {"op":"reset"} {"op":"status"}
aid -> game:  {"ev":"start","id"} {"ev":"delta","id","text"} {"ev":"done","id"}
              {"ev":"error","id","kind","msg","partial","retryable"}
              {"ev":"tool","id","tool","status","title"}
              {"ev":"remote_user","id","text"} {"ev":"status",...}
              kind: offline|timeout|auth|rate_limit|server|interrupted|cancelled
"""
import base64
import http.client
import json
import os
import socket
import sys
import threading
import urllib.parse

CONNECT_TIMEOUT = 6.0
BACKOFF_START = 0.5
BACKOFF_MAX = 5.0
MSG_LIMIT = 180
TITLE_LIMIT = 80
DEFAULT_URL = "http://127.0.0.1:4096"
DEFAULT_WORKDIR = "/mnt/mmc/Roms/APPS/RGDS-Agents"
DEFAULT_PASSWORD_FILE = "/userdata/opencode/server.password"
_INPUT_KEYS = ("title", "description", "command", "cmd", "path", "query")


class AidError(Exception):
    def __init__(self, kind, msg, retryable):
        super().__init__(kind)
        self.kind = kind
        self.msg = msg
        self.retryable = retryable


def redact(secret, text, limit=MSG_LIMIT):
    text = str(text or "")
    if secret:
        token = base64.b64encode(b"opencode:" + secret.encode("utf-8")).decode("ascii")
        text = text.replace(secret, "[redacted]").replace(token, "[redacted]")
    if len(text) > limit:
        text = text[:limit]
    return text


def clip(text, limit=TITLE_LIMIT):
    text = " ".join(str(text).split())
    if len(text) <= limit:
        return text
    return text[:limit]


def load_password():
    env = os.environ.get("OPENCODE_PASSWORD")
    if env:
        return env
    path = os.environ.get("RGDS_OPENCODE_PASSWORD_FILE", DEFAULT_PASSWORD_FILE)
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        raise AidError("auth", "opencode password missing", False) from None
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    if raw.endswith(b"\r"):
        raw = raw[:-1]
    if not raw:
        raise AidError("auth", "opencode password missing", False)
    return raw.decode("utf-8", "replace")


def basic_header(password):
    token = base64.b64encode(b"opencode:" + password.encode("utf-8")).decode("ascii")
    return "Basic " + token


def http_kind(status):
    if status in (401, 403):
        return "auth", False
    if status == 429:
        return "rate_limit", True
    return "server", True


def short_meta(meta):
    if not isinstance(meta, dict):
        return ""
    for key in ("title", "description"):
        item = meta.get(key)
        if isinstance(item, str) and item.strip():
            return clip(item)
    return ""


def short_input(value):
    if isinstance(value, dict):
        for key in _INPUT_KEYS:
            item = value.get(key)
            if isinstance(item, str) and item.strip():
                return clip(item)
        return clip(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    if isinstance(value, str):
        return clip(value)
    if value is None:
        return ""
    return clip(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def short_content(content):
    if isinstance(content, str):
        return clip(content)
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
        if parts:
            return clip(" ".join(parts))
    return ""


def short_failure(error, meta):
    if isinstance(error, dict):
        msg = error.get("message")
        if isinstance(msg, str) and msg.strip():
            return clip(msg)
    elif isinstance(error, str) and error.strip():
        return clip(error)
    return short_meta(meta) or "error"


def clear_read_timeout(resp):
    resp.fp.raw._sock.settimeout(None)


def iter_sse(resp):
    data = []
    while True:
        line = resp.readline()
        if not line:
            if data:
                raw = b"\n".join(data).decode("utf-8", "replace")
                data = []
                event = _load_event(raw)
                if event is not None:
                    yield event
            return
        if line in (b"\n", b"\r\n"):
            if not data:
                continue
            raw = b"\n".join(data).decode("utf-8", "replace")
            data = []
            event = _load_event(raw)
            if event is not None:
                yield event
            continue
        if line.startswith(b"data:"):
            piece = line[5:]
            if piece.startswith(b" "):
                piece = piece[1:]
            data.append(piece.rstrip(b"\r\n"))


def _load_event(raw):
    try:
        event = json.loads(raw)
    except ValueError:
        return None
    if isinstance(event, dict):
        return event
    return None


def _part_key(data):
    mid = data.get("assistantMessageID")
    if not isinstance(mid, str):
        mid = ""
    ordinal = data.get("ordinal")
    if isinstance(ordinal, bool) or not isinstance(ordinal, (int, float, str)):
        ordinal = 0
    try:
        ordinal = int(ordinal)
    except (TypeError, ValueError):
        ordinal = 0
    return (mid, ordinal)


def _tool_event(rid, name, status, title):
    return {"ev": "tool", "id": rid, "tool": name, "status": status, "title": title}


class _Turn:
    def __init__(self, rid):
        self.rid = rid
        self.parts = []
        self.closed = False
        self.chars = {}
        self.tools = {}

    def partial(self):
        return "".join(self.parts)


class TurnTracker:
    """Pure reducer. One active turn. No sockets."""

    def __init__(self):
        self.session_id = None
        self.turn = None
        self.handheld = set()

    def set_session(self, session_id):
        self.session_id = session_id

    def reset(self, session_id):
        self.session_id = session_id
        self.turn = None
        self.handheld.clear()

    def begin(self, rid):
        self.turn = _Turn(rid)

    def note_inbox(self, inbox_id):
        if isinstance(inbox_id, str) and inbox_id:
            self.handheld.add(inbox_id)

    def apply(self, event):
        if not isinstance(event, dict):
            return []
        data = event.get("data")
        if not isinstance(data, dict):
            return []
        sid = data.get("sessionID")
        if not isinstance(sid, str) or not self.session_id or sid != self.session_id:
            return []
        fn = _HANDLERS.get(event.get("type"))
        if fn is None:
            return []
        return fn(self, data)

    def _open(self):
        turn = self.turn
        if turn is None or turn.closed:
            return None
        return turn

    def _inbox(self, data):
        item = data.get("item")
        if not isinstance(item, dict) or item.get("type") != "user":
            return []
        inbox_id = data.get("inboxID")
        payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
        meta = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
        if inbox_id in self.handheld or meta.get("source") == "rgds-handheld":
            return []
        text = payload.get("text") if isinstance(payload.get("text"), str) else ""
        rid = "pc-%s" % (inbox_id if isinstance(inbox_id, str) and inbox_id else "turn")
        self.turn = _Turn(rid)
        return [
            {"ev": "remote_user", "id": rid, "text": text},
            {"ev": "start", "id": rid},
        ]

    def _delta(self, data):
        turn = self._open()
        if turn is None:
            return []
        piece = data.get("delta")
        if not isinstance(piece, str) or piece == "":
            return []
        key = _part_key(data)
        turn.chars[key] = turn.chars.get(key, 0) + len(piece)
        turn.parts.append(piece)
        return [{"ev": "delta", "id": turn.rid, "text": piece}]

    def _ended(self, data):
        turn = self._open()
        if turn is None:
            return []
        text = data.get("text") if isinstance(data.get("text"), str) else ""
        key = _part_key(data)
        emitted = turn.chars.get(key, 0)
        if len(text) <= emitted:
            return []
        suffix = text[emitted:]
        turn.chars[key] = len(text)
        turn.parts.append(suffix)
        return [{"ev": "delta", "id": turn.rid, "text": suffix}]

    def _remember_tool(self, data):
        turn = self._open()
        if turn is None:
            return []
        name = data.get("name")
        if not isinstance(name, str) or not name:
            name = "tool"
        turn.tools[data.get("id")] = name
        return []

    def _tool_name(self, turn, data):
        name = turn.tools.get(data.get("id"))
        if isinstance(name, str) and name:
            return name
        return "tool"

    def _tool_called(self, data):
        turn = self._open()
        if turn is None:
            return []
        return [_tool_event(turn.rid, self._tool_name(turn, data), "running", short_input(data.get("input")))]

    def _tool_progress(self, data):
        turn = self._open()
        if turn is None:
            return []
        title = short_meta(data.get("metadata"))
        if not title:
            return []
        return [_tool_event(turn.rid, self._tool_name(turn, data), "running", title)]

    def _tool_success(self, data):
        turn = self._open()
        if turn is None:
            return []
        title = short_meta(data.get("metadata")) or short_content(data.get("content")) or "completed"
        return [_tool_event(turn.rid, self._tool_name(turn, data), "completed", title)]

    def _tool_failed(self, data):
        turn = self._open()
        if turn is None:
            return []
        title = short_failure(data.get("error"), data.get("metadata"))
        return [_tool_event(turn.rid, self._tool_name(turn, data), "error", title)]

    def _permission(self, data):
        turn = self._open()
        if turn is None:
            return []
        action = data.get("action")
        if not isinstance(action, str) or not action:
            action = "permission"
        message = data.get("message")
        if not isinstance(message, str) or not message.strip():
            resources = data.get("resources")
            if resources is None:
                message = action
            else:
                message = json.dumps(resources, ensure_ascii=False, separators=(",", ":"))
        return [_tool_event(turn.rid, action, "running", clip("waiting permission: " + message))]

    def _finish(self, _data):
        turn = self._open()
        if turn is None:
            return []
        turn.closed = True
        return [{"ev": "done", "id": turn.rid}]

    def _failed(self, data):
        err = data.get("error") if isinstance(data.get("error"), dict) else {}
        kind, retryable = http_kind(err.get("status") or 0)
        msg = err.get("message") if isinstance(err.get("message"), str) else "error"
        return self._fail(kind, msg, retryable)

    def _interrupted(self, data):
        kind = "cancelled" if data.get("reason") == "user" else "interrupted"
        return self._fail(kind, "", True)

    def _fail(self, kind, msg, retryable):
        turn = self._open()
        if turn is None:
            return []
        partial = turn.partial()
        turn.closed = True
        return [{
            "ev": "error",
            "id": turn.rid,
            "kind": kind,
            "msg": msg,
            "partial": partial,
            "retryable": retryable,
        }]


_HANDLERS = {
    "session.inbox.enqueued": TurnTracker._inbox,
    "session.text.delta": TurnTracker._delta,
    "session.text.ended": TurnTracker._ended,
    "session.tool.input.started": TurnTracker._remember_tool,
    "session.tool.called": TurnTracker._tool_called,
    "session.tool.progress": TurnTracker._tool_progress,
    "session.tool.success": TurnTracker._tool_success,
    "session.tool.failed": TurnTracker._tool_failed,
    "session.execution.succeeded": TurnTracker._finish,
    "session.idle": TurnTracker._finish,
    "session.execution.failed": TurnTracker._failed,
    "session.step.failed": TurnTracker._failed,
    "session.execution.interrupted": TurnTracker._interrupted,
    "permission.asked": TurnTracker._permission,
}


class OpenCodeClient:
    def __init__(self):
        self.base_url = os.environ.get("RGDS_OPENCODE_URL", DEFAULT_URL).rstrip("/")
        self.workdir = os.environ.get("RGDS_OPENCODE_WORKDIR", DEFAULT_WORKDIR)
        self.on_event = None
        self._secret = ""
        self.stopped = threading.Event()
        self.thread = None
        self._stream = None
        self._stream_lock = threading.Lock()

    def start(self):
        self.stopped.clear()
        self.thread = threading.Thread(target=self._loop, name="opencode-sse", daemon=True)
        self.thread.start()

    def stop(self):
        self.stopped.set()
        with self._stream_lock:
            conn = self._stream
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
        if self.thread is not None:
            self.thread.join(timeout=CONNECT_TIMEOUT + 2)

    def info(self):
        return self._json("GET", "/api/info")

    def list_sessions(self):
        payload = self._json("GET", "/api/session", query={
            "directory": self.workdir,
            "order": "desc",
            "limit": "10",
            "parentID": "null",
            "archived": "false",
        })
        data = payload.get("data")
        if not isinstance(data, list):
            return []
        return [item for item in data if isinstance(item, dict) and isinstance(item.get("id"), str)]

    def create_session(self):
        payload = self._json("POST", "/api/session", body={
            "location": {"directory": self.workdir},
        })
        data = payload.get("data")
        if not isinstance(data, dict) or not isinstance(data.get("id"), str) or not data["id"]:
            raise AidError("server", "session id missing", True)
        return data["id"]

    def prompt(self, session_id, text, rid):
        payload = self._json(
            "POST",
            "/api/session/" + urllib.parse.quote(session_id, safe="") + "/prompt",
            body={"text": text, "metadata": {"source": "rgds-handheld", "rid": rid}},
        )
        data = payload.get("data")
        if isinstance(data, dict) and isinstance(data.get("id"), str):
            return data["id"]
        return ""

    def interrupt(self, session_id):
        self._json("POST", "/api/session/" + urllib.parse.quote(session_id, safe="") + "/interrupt")

    def _connect(self):
        parsed = urllib.parse.urlparse(self.base_url)
        host = parsed.hostname
        if not host:
            raise AidError("offline", "bad opencode url", True)
        if parsed.scheme == "https":
            port = parsed.port or 443
            return http.client.HTTPSConnection(host, port, timeout=CONNECT_TIMEOUT)
        if parsed.scheme == "http":
            port = parsed.port or 80
            return http.client.HTTPConnection(host, port, timeout=CONNECT_TIMEOUT)
        raise AidError("offline", "bad opencode url", True)

    def _json(self, method, path, query=None, body=None):
        _resp, raw = self._request(method, path, query=query, body=body, stream=False)
        if not raw:
            return {}
        try:
            payload = json.loads(raw)
        except ValueError:
            raise AidError("server", "bad json", True) from None
        if not isinstance(payload, dict):
            raise AidError("server", "bad json", True)
        return payload

    def _request(self, method, path, query=None, body=None, stream=False):
        password = load_password()
        self._secret = password
        conn = None
        try:
            conn = self._connect()
            target = path
            if query:
                target += "?" + urllib.parse.urlencode(query)
            data = None
            headers = {
                "Authorization": basic_header(password),
                "Accept": "text/event-stream" if stream else "application/json",
            }
            if body is not None:
                data = json.dumps(body, ensure_ascii=False).encode("utf-8")
                headers["Content-Type"] = "application/json"
            conn.request(method, target, body=data, headers=headers)
            resp = conn.getresponse()
        except AidError:
            if conn is not None:
                conn.close()
            raise
        except (TimeoutError, socket.timeout) as exc:
            if conn is not None:
                conn.close()
            raise AidError("timeout", redact(password, exc), True) from None
        except OSError as exc:
            if conn is not None:
                conn.close()
            raise AidError("offline", redact(password, exc), True) from None
        except http.client.HTTPException as exc:
            if conn is not None:
                conn.close()
            raise AidError("server", redact(password, exc), True) from None
        if resp.status in (301, 302, 303, 307, 308):
            try:
                resp.read()
            finally:
                resp.close()
                conn.close()
            raise AidError("server", "HTTP %s" % resp.status, True)
        if resp.status < 200 or resp.status >= 300:
            try:
                raw = resp.read(4096).decode("utf-8", "replace")
            finally:
                resp.close()
                conn.close()
            kind, retryable = http_kind(resp.status)
            detail = ("HTTP %s %s" % (resp.status, raw[:300])).strip()
            raise AidError(kind, redact(password, detail), retryable)
        if stream:
            try:
                clear_read_timeout(resp)
            except Exception:
                resp.close()
                conn.close()
                raise AidError("server", "sse socket", True) from None
            with self._stream_lock:
                self._stream = conn
            return resp, b""
        try:
            raw = resp.read()
        finally:
            resp.close()
            conn.close()
        return None, raw

    def _dispatch(self, event):
        fn = self.on_event
        if fn is None:
            return
        try:
            fn(event)
        except Exception:
            return

    def _loop(self):
        delay = BACKOFF_START
        while not self.stopped.is_set():
            resp = None
            received = False
            try:
                resp, _raw = self._request("GET", "/api/event", stream=True)
                for event in iter_sse(resp):
                    if self.stopped.is_set():
                        break
                    received = True
                    self._dispatch(event)
            except AidError:
                pass
            except Exception:
                pass
            finally:
                with self._stream_lock:
                    conn = self._stream
                    self._stream = None
                if resp is not None:
                    try:
                        resp.close()
                    except Exception:
                        pass
                if conn is not None:
                    try:
                        conn.close()
                    except Exception:
                        pass
            if self.stopped.is_set() or self.stopped.wait(delay):
                return
            if received:
                delay = BACKOFF_START
            else:
                delay = min(BACKOFF_MAX, delay * 2)


class Conn:
    def __init__(self, sock, client):
        self.sock = sock
        self.client = client
        self.tracker = TurnTracker()
        self.state_lock = threading.Lock()
        self.send_lock = threading.Lock()
        client.on_event = self.on_event

    def send(self, ev):
        ev = self._scrub(ev)
        data = (json.dumps(ev, ensure_ascii=False) + "\n").encode("utf-8")
        with self.send_lock:
            try:
                self.sock.sendall(data)
            except OSError:
                pass

    def _scrub(self, ev):
        secret = self.client._secret
        if not secret:
            return ev
        out = {}
        for key, value in ev.items():
            if isinstance(value, str):
                out[key] = redact(secret, value)
            else:
                out[key] = value
        return out

    def _error(self, rid, err, partial=""):
        self.send({
            "ev": "error",
            "id": rid,
            "kind": err.kind,
            "msg": err.msg,
            "partial": partial,
            "retryable": err.retryable,
        })

    def on_event(self, event):
        with self.state_lock:
            events = list(self.tracker.apply(event))
        for ev in events:
            self.send(ev)

    def attach(self):
        try:
            found = self.client.list_sessions()
        except AidError:
            return
        if not found:
            return
        with self.state_lock:
            if not self.tracker.session_id:
                self.tracker.set_session(found[0]["id"])

    def ensure_session(self):
        with self.state_lock:
            current = self.tracker.session_id
        if current:
            return current
        found = self.client.list_sessions()
        sid = found[0]["id"] if found else self.client.create_session()
        with self.state_lock:
            if not self.tracker.session_id:
                self.tracker.set_session(sid)
            return self.tracker.session_id

    def chat(self, rid, text):
        try:
            self._chat(rid, text)
        except AidError as err:
            self._error(rid, err)
        except Exception as exc:
            self._error(rid, AidError("server", redact(self.client._secret, exc), True))

    def _chat(self, rid, text):
        try:
            sid = self.ensure_session()
        except AidError as err:
            self._error(rid, err)
            return
        with self.state_lock:
            self.tracker.set_session(sid)
            self.tracker.begin(rid)
        self.send({"ev": "start", "id": rid})
        try:
            inbox = self.client.prompt(sid, text, rid)
        except AidError as err:
            with self.state_lock:
                partial = ""
                turn = self.tracker.turn
                if turn is not None and turn.rid == rid and not turn.closed:
                    partial = turn.partial()
                    turn.closed = True
            self._error(rid, err, partial)
            return
        with self.state_lock:
            self.tracker.note_inbox(inbox)

    def cancel(self, rid):
        with self.state_lock:
            sid = self.tracker.session_id
            turn = self.tracker.turn
            active = turn is not None and turn.rid == rid and not turn.closed
        if not sid or not active:
            return
        try:
            self.client.interrupt(sid)
        except AidError as err:
            with self.state_lock:
                turn = self.tracker.turn
                if turn is None or turn.rid != rid or turn.closed:
                    return
                partial = turn.partial()
                turn.closed = True
            self._error(rid, err, partial)

    def reset(self):
        try:
            sid = self.client.create_session()
        except AidError as err:
            self._error("", err)
            return
        with self.state_lock:
            self.tracker.reset(sid)
        self.send({"ev": "status", "reset": True, "session_id": sid})

    def status(self):
        with self.state_lock:
            sid = self.tracker.session_id
        try:
            info = self.client.info()
        except AidError:
            self.send({"ev": "status", "net": "offline", "session_id": sid})
            return
        ev = {"ev": "status", "net": "ok", "session_id": sid}
        version = info.get("version")
        if isinstance(version, str):
            ev["version"] = version
        self.send(ev)

    def serve(self):
        self.client.start()
        threading.Thread(target=self.attach, name="opencode-attach", daemon=True).start()
        try:
            stream = self.sock.makefile("rb")
            try:
                for line in stream:
                    self._op(line)
            finally:
                stream.close()
        finally:
            self.client.stop()
            try:
                self.sock.close()
            except OSError:
                pass

    def _op(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        if not isinstance(msg, dict):
            return
        op = msg.get("op")
        try:
            if op == "chat" and isinstance(msg.get("text"), str):
                rid = msg.get("id")
                if not isinstance(rid, str) or not rid:
                    rid = "r"
                threading.Thread(target=self.chat, args=(rid, msg["text"]), daemon=True).start()
            elif op == "cancel" and isinstance(msg.get("id"), str):
                self.cancel(msg["id"])
            elif op == "reset":
                self.reset()
            elif op == "status":
                self.status()
        except AidError as err:
            rid = msg.get("id") if isinstance(msg.get("id"), str) else ""
            self._error(rid, err)


def listen(host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(2)
    return srv


def main():
    # The game thread that spawns us blocks most signals. Undo that so quit can SIGTERM.
    try:
        import signal
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
    except Exception:
        pass
    port = int(os.environ.get("RGDS_AI_PORT", "7788"))
    srv = listen("127.0.0.1", port)
    bound = srv.getsockname()
    print("rgds-aid listening on %s:%d" % (bound[0], bound[1]), file=sys.stderr, flush=True)
    while True:
        conn, _addr = srv.accept()
        client = OpenCodeClient()
        threading.Thread(target=Conn(conn, client).serve, daemon=True).start()


if __name__ == "__main__":
    main()
