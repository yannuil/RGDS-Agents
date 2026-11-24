"""TurnTracker and a local OpenCode v2.4.0 mock. No device and no port 7788."""
import base64
import http.client
import importlib.util
import io
import json
import os
import queue
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SPEC = importlib.util.spec_from_file_location(
    "rgds_aid", os.path.join(_ROOT, "rgds-aid.py"))
AID = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(AID)

_ENV_KEYS = (
    "RGDS_OPENCODE_URL",
    "RGDS_OPENCODE_WORKDIR",
    "RGDS_OPENCODE_PASSWORD_FILE",
    "OPENCODE_PASSWORD",
    "RGDS_AI_CONFIG",
    "RGDS_AI_KEY",
)
_WORKDIR = "/mnt/mmc/Roms/APPS/RGDS-Agents"
_GONE = (
    "load_cfg",
    "resolve_cfg_path",
    "CFG_PATH",
    "MINIMAX_BASE",
    "MINIMAX_MODEL",
    "ThinkStrip",
    "NoRedirect",
    "tls_ctx",
    "delta_text",
    "IDLE_TIMEOUT",
)


def _v2(etype, **data):
    return {"id": "evt", "type": etype, "data": data}


class TrackerTest(unittest.TestCase):
    def setUp(self):
        self.tracker = AID.TurnTracker()
        self.tracker.set_session("ses_1")
        self.tracker.begin("r1")

    def test_legacy_helpers_are_gone(self):
        for name in _GONE:
            self.assertFalse(hasattr(AID, name), name)

    def test_delta_and_ended_do_not_repeat_text(self):
        out = []
        out += self.tracker.apply(_v2(
            "session.text.delta", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, delta="Hello"))
        out += self.tracker.apply(_v2(
            "session.text.delta", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, delta=" "))
        out += self.tracker.apply(_v2(
            "session.text.ended", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, text="Hello world"))
        out += self.tracker.apply(_v2(
            "session.text.ended", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, text="Hello world"))
        self.assertEqual([ev["text"] for ev in out], ["Hello", " ", "world"])

    def test_ended_alone_emits_the_whole_text_once(self):
        first = self.tracker.apply(_v2(
            "session.text.ended", sessionID="ses_1",
            assistantMessageID="m1", ordinal=1, text="Hi"))
        second = self.tracker.apply(_v2(
            "session.text.ended", sessionID="ses_1",
            assistantMessageID="m1", ordinal=1, text="Hi"))
        self.assertEqual(first, [{"ev": "delta", "id": "r1", "text": "Hi"}])
        self.assertEqual(second, [])

    def test_other_session_is_ignored(self):
        out = self.tracker.apply(_v2(
            "session.text.delta", sessionID="ses_other",
            assistantMessageID="m1", ordinal=0, delta="nope"))
        self.assertEqual(out, [])

    def test_text_started_emits_nothing(self):
        out = self.tracker.apply(_v2(
            "session.text.started", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0))
        self.assertEqual(out, [])

    def test_tool_lifecycle(self):
        events = []
        events += self.tracker.apply(_v2(
            "session.tool.input.started", sessionID="ses_1",
            assistantMessageID="m1", id="t1", name="bash"))
        events += self.tracker.apply(_v2(
            "session.tool.called", sessionID="ses_1",
            assistantMessageID="m1", id="t1",
            input={"command": "sleep 25 && uname -a"}, executed=False))
        events += self.tracker.apply(_v2(
            "session.tool.progress", sessionID="ses_1",
            assistantMessageID="m1", id="t1",
            metadata={"title": "still running"}))
        events += self.tracker.apply(_v2(
            "session.tool.success", sessionID="ses_1",
            assistantMessageID="m1", id="t1",
            content="Linux\n", metadata={}, executed=True))
        self.assertEqual(events, [
            {"ev": "tool", "id": "r1", "tool": "bash", "status": "running",
             "title": "sleep 25 && uname -a", "call_id": "t1"},
            {"ev": "tool", "id": "r1", "tool": "bash", "status": "running",
             "title": "still running", "call_id": "t1"},
            {"ev": "tool", "id": "r1", "tool": "bash", "status": "completed",
             "title": "Linux", "call_id": "t1"},
        ])

    def test_tool_failed(self):
        self.tracker.apply(_v2(
            "session.tool.input.started", sessionID="ses_1",
            assistantMessageID="m1", id="t1", name="bash"))
        out = self.tracker.apply(_v2(
            "session.tool.failed", sessionID="ses_1",
            assistantMessageID="m1", id="t1",
            error={"message": "exit 1"}, metadata={}, executed=True))
        self.assertEqual(out, [{
            "ev": "tool", "id": "r1", "tool": "bash", "status": "error",
            "title": "exit 1", "call_id": "t1",
        }])

    def test_progress_without_a_title_emits_nothing(self):
        out = self.tracker.apply(_v2(
            "session.tool.progress", sessionID="ses_1",
            assistantMessageID="m1", id="t1", metadata={"bytes": 4}))
        self.assertEqual(out, [])

    def test_permission_asked(self):
        out = self.tracker.apply(_v2(
            "permission.asked", sessionID="ses_1", id="p1",
            action="bash", resources=["/tmp"], message="rm a file"))
        self.assertEqual(out, [{
            "ev": "tool", "id": "r1", "tool": "bash", "status": "running",
            "title": "waiting permission: rm a file", "call_id": "p1",
        }])

    def test_failed_then_idle_emits_error_only(self):
        self.tracker.apply(_v2(
            "session.text.delta", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, delta="Hi"))
        err = self.tracker.apply(_v2(
            "session.execution.failed", sessionID="ses_1",
            error={"message": "boom", "status": 500}))
        idle = self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        step = self.tracker.apply(_v2(
            "session.step.failed", sessionID="ses_1",
            error={"message": "again", "status": 500}))
        self.assertEqual(err, [{
            "ev": "error", "id": "r1", "kind": "server", "msg": "boom",
            "partial": "Hi", "retryable": True,
        }])
        self.assertEqual(idle, [])
        self.assertEqual(step, [])

    def test_auth_and_rate_limit_kinds(self):
        auth = self.tracker.apply(_v2(
            "session.execution.failed", sessionID="ses_1",
            error={"message": "no", "status": 401}))
        self.tracker.begin("r2")
        limited = self.tracker.apply(_v2(
            "session.step.failed", sessionID="ses_1",
            error={"message": "slow", "status": 429}))
        self.assertEqual(auth[0]["kind"], "auth")
        self.assertFalse(auth[0]["retryable"])
        self.assertEqual(limited[0]["kind"], "rate_limit")
        self.assertTrue(limited[0]["retryable"])
        self.assertEqual(limited[0]["id"], "r2")

    def test_user_interrupt_suppresses_done(self):
        err = self.tracker.apply(_v2(
            "session.execution.interrupted", sessionID="ses_1", reason="user"))
        idle = self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        done = self.tracker.apply(_v2("session.execution.succeeded", sessionID="ses_1"))
        self.assertEqual(err[0]["kind"], "cancelled")
        self.assertEqual(err[0]["msg"], "")
        self.assertTrue(err[0]["retryable"])
        self.assertEqual(idle, [])
        self.assertEqual(done, [])

    def test_shutdown_interrupt_kind(self):
        err = self.tracker.apply(_v2(
            "session.execution.interrupted", sessionID="ses_1", reason="shutdown"))
        self.assertEqual(err[0]["kind"], "interrupted")

    def test_succeeded_and_idle_emit_one_done(self):
        first = self.tracker.apply(_v2("session.execution.succeeded", sessionID="ses_1"))
        second = self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        self.assertEqual(first, [{"ev": "done", "id": "r1"}])
        self.assertEqual(second, [])

    def test_handheld_inbox_is_not_a_remote_user(self):
        self.tracker.note_inbox("inb_1")
        echoed = self.tracker.apply(_v2(
            "session.inbox.enqueued", sessionID="ses_1", inboxID="inb_9",
            item={"type": "user", "payload": {
                "text": "hello", "metadata": {"source": "rgds-handheld", "rid": "r1"},
            }}))
        known = self.tracker.apply(_v2(
            "session.inbox.enqueued", sessionID="ses_1", inboxID="inb_1",
            item={"type": "user", "payload": {"text": "hello", "metadata": {}}}))
        self.assertEqual(echoed, [])
        self.assertEqual(known, [])
        self.assertEqual(self.tracker.turn.rid, "r1")

    def test_pc_inbox_starts_a_turn(self):
        self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        out = []
        out += self.tracker.apply(_v2(
            "session.inbox.enqueued", sessionID="ses_1", inboxID="inb_pc",
            item={"type": "user", "payload": {"text": "from the desk", "metadata": {}}}))
        out += self.tracker.apply(_v2(
            "session.tool.input.started", sessionID="ses_1",
            assistantMessageID="m1", id="t1", name="bash"))
        out += self.tracker.apply(_v2(
            "session.tool.called", sessionID="ses_1",
            assistantMessageID="m1", id="t1", input={"command": "uname"}, executed=False))
        out += self.tracker.apply(_v2(
            "session.text.delta", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, delta="Linux"))
        out += self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        self.assertEqual(out, [
            {"ev": "remote_user", "id": "pc-inb_pc", "text": "from the desk"},
            {"ev": "start", "id": "pc-inb_pc"},
            {"ev": "tool", "id": "pc-inb_pc", "tool": "bash", "status": "running",
             "title": "uname", "call_id": "t1"},
            {"ev": "delta", "id": "pc-inb_pc", "text": "Linux"},
            {"ev": "done", "id": "pc-inb_pc"},
        ])

    def test_pc_inbox_waits_behind_the_open_turn(self):
        queued = self.tracker.apply(_v2(
            "session.inbox.enqueued", sessionID="ses_1", inboxID="inb_pc",
            item={"type": "user", "payload": {"text": "from the desk", "metadata": {}}}))
        self.assertEqual(queued, [])
        self.assertEqual(self.tracker.turn.rid, "r1")
        closed = self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        self.assertEqual([ev["ev"] for ev in closed], ["done", "remote_user", "start"])
        self.assertEqual(closed[0]["id"], "r1")
        self.assertEqual(closed[1]["id"], "pc-inb_pc")
        self.assertEqual(closed[1]["text"], "from the desk")
        self.assertEqual(closed[2]["id"], "pc-inb_pc")

    def test_supersede_fence_ignores_the_previous_interrupt(self):
        extra = self.tracker.begin("r2")
        self.assertEqual(extra[0]["id"], "r1")
        self.assertEqual(extra[0]["kind"], "cancelled")
        ignored = self.tracker.apply(_v2(
            "session.execution.interrupted", sessionID="ses_1", reason="user"))
        ignored += self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        self.assertEqual(ignored, [])
        self.assertFalse(self.tracker.turn.closed)
        self.assertEqual(self.tracker.turn.rid, "r2")
        delta = self.tracker.apply(_v2(
            "session.text.delta", sessionID="ses_1",
            assistantMessageID="m1", ordinal=0, delta="next"))
        done = self.tracker.apply(_v2("session.idle", sessionID="ses_1"))
        self.assertEqual(delta, [{"ev": "delta", "id": "r2", "text": "next"}])
        self.assertEqual(done, [{"ev": "done", "id": "r2"}])


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, _fmt, *_args):
        return

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def _handle(self):
        mock = self.server.mock
        parsed = urllib.parse.urlparse(self.path)
        body = None
        if self.command == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            if raw:
                try:
                    body = json.loads(raw.decode())
                except ValueError:
                    body = None
        call = {
            "method": self.command,
            "path": parsed.path,
            "query": urllib.parse.parse_qs(parsed.query),
            "body": body,
            "authorization": self.headers.get("Authorization", ""),
        }
        with mock.lock:
            mock.calls.append(call)
        expect = "Basic " + base64.b64encode(b"opencode:" + mock.password.encode()).decode()
        if call["authorization"] != expect:
            self._bytes(401, b"denied")
            return
        path = parsed.path
        if mock.redirect_status and path != "/api/event":
            self._redirect(mock)
            return
        if path == "/api/info" and self.command == "GET":
            if mock.fault == "info":
                mock.fault = ""
                self._incomplete()
                return
            self._json(200, {
                "version": "2.4.0", "pid": 1, "hostname": "mock",
                "urls": [mock.url], "paths": {"tmp": "/tmp"},
            })
            return
        if path == "/api/session" and self.command == "GET":
            if mock.list_gate is not None:
                with mock.lock:
                    mock.list_hits += 1
                    hits = mock.list_hits
                if hits >= 2 and mock.list_ready is not None:
                    mock.list_ready.set()
                mock.list_gate.wait(5)
            with mock.lock:
                data = list(mock.sessions)
            self._json(200, {"data": data, "cursor": {}})
            with mock.lock:
                mock.lists_done += 1
            return
        if path == "/api/session" and self.command == "POST":
            if mock.create_gate is not None:
                with mock.lock:
                    mock.create_holds += 1
                    hold = mock.create_holds
                if hold == 1:
                    if mock.create_entered is not None:
                        mock.create_entered.set()
                    mock.create_gate.wait(5)
            if mock.fault == "create":
                mock.fault = ""
                self._incomplete()
                return
            directory = ""
            if isinstance(body, dict):
                loc = body.get("location")
                if isinstance(loc, dict) and isinstance(loc.get("directory"), str):
                    directory = loc["directory"]
            with mock.lock:
                mock.seq += 1
                sid = "ses_%d" % mock.seq
                mock.sessions.insert(0, {"id": sid, "directory": directory})
            self._json(200, {"data": {"id": sid, "directory": directory}})
            return
        if path == "/api/event" and self.command == "GET":
            self._sse(mock)
            return
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "session":
            action = parts[3]
            if action == "prompt" and self.command == "POST":
                if mock.fail_prompt:
                    self._bytes(500, ("boom " + mock.password).encode())
                    return
                with mock.lock:
                    mock.seq += 1
                    inbox = "inb_%d" % mock.seq
                self._json(200, {"data": {"id": inbox}})
                return
            if action == "interrupt" and self.command == "POST":
                self._json(200, {})
                return
        self._json(404, {"message": "missing"})

    def _redirect(self, mock):
        self.send_response(mock.redirect_status)
        self.send_header("Location", "http://127.0.0.1/stolen")
        self.end_headers()
        self.wfile.flush()
        if mock.redirect_entered is not None:
            mock.redirect_entered.set()
        if mock.redirect_hold is not None:
            mock.redirect_hold.wait(5)

    def _incomplete(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "80")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b"{")
        self.close_connection = True

    def _json(self, code, payload):
        self._bytes(code, json.dumps(payload).encode())

    def _bytes(self, code, raw):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _sse(self, mock):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        hello = json.dumps({"id": "hello", "type": "server.connected", "data": {}}).encode()
        self.wfile.write(b"data: " + hello + b"\n\n")
        self.wfile.flush()
        pending = queue.Queue()
        with mock.lock:
            mock.sse_queues.append(pending)
            mock.sse_opens += 1
        try:
            while not mock.closed:
                try:
                    item = pending.get(timeout=0.2)
                except queue.Empty:
                    continue
                if item is None:
                    return
                raw = json.dumps(item).encode()
                self.wfile.write(b"data: " + raw + b"\n\n")
                self.wfile.flush()
        except OSError:
            return
        finally:
            with mock.lock:
                if pending in mock.sse_queues:
                    mock.sse_queues.remove(pending)


class MockOpenCode:
    def __init__(self, password, sessions=None):
        self.password = password
        self.sessions = list(sessions or [])
        self.lock = threading.Lock()
        self.calls = []
        self.sse_queues = []
        self.sse_opens = 0
        self.seq = 0
        self.closed = False
        self.fail_prompt = False
        self.fault = ""
        self.redirect_status = 0
        self.redirect_hold = None
        self.redirect_entered = None
        self.list_gate = None
        self.list_ready = None
        self.list_hits = 0
        self.lists_done = 0
        self.create_gate = None
        self.create_entered = None
        self.create_holds = 0
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.httpd.mock = self
        self.httpd.daemon_threads = True
        self.url = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.closed = True
        with self.lock:
            queues = list(self.sse_queues)
        for pending in queues:
            pending.put(None)
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def emit(self, event):
        with self.lock:
            queues = list(self.sse_queues)
        for pending in queues:
            pending.put(event)

    def drop_sse(self):
        with self.lock:
            queues = list(self.sse_queues)
        for pending in queues:
            pending.put(None)

    def wait_calls(self, pred, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                found = [call for call in self.calls if pred(call)]
            if found:
                return found
            time.sleep(0.02)
        with self.lock:
            return [call for call in self.calls if pred(call)]

    def wait_opens(self, count, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                if self.sse_opens >= count:
                    return self.sse_opens
            time.sleep(0.02)
        with self.lock:
            return self.sse_opens


class AidServer:
    def __init__(self):
        self.srv = AID.listen("127.0.0.1", 0)
        self.port = self.srv.getsockname()[1]
        self._stop = threading.Event()
        self._conns = []
        self._lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()

    def _run(self):
        while not self._stop.is_set():
            try:
                self.srv.settimeout(0.2)
                conn, _addr = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            client = AID.OpenCodeClient()
            worker = threading.Thread(target=AID.Conn(conn, client).serve, daemon=True)
            with self._lock:
                self._conns.append(worker)
            worker.start()

    def stop(self):
        self._stop.set()
        try:
            self.srv.close()
        except OSError:
            pass
        self.thread.join(timeout=2)
        with self._lock:
            workers = list(self._conns)
        for worker in workers:
            worker.join(timeout=2)


class Ndjson:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), 2)
        self.buf = b""

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def recv(self, timeout=3):
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("aid closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.decode())

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class WireTest(unittest.TestCase):
    def setUp(self):
        self.password = "pw-do-not-leak"
        self._env = {key: os.environ.get(key) for key in _ENV_KEYS}
        self.mock = MockOpenCode(self.password, sessions=[
            {"id": "ses_new"},
            {"id": "ses_old"},
        ])
        self.mock.start()
        os.environ["RGDS_OPENCODE_URL"] = self.mock.url
        os.environ["RGDS_OPENCODE_WORKDIR"] = _WORKDIR
        os.environ["OPENCODE_PASSWORD"] = self.password
        os.environ.pop("RGDS_OPENCODE_PASSWORD_FILE", None)
        os.environ.pop("RGDS_AI_CONFIG", None)
        os.environ.pop("RGDS_AI_KEY", None)
        self.aid = AidServer()
        self.aid.start()
        self.client = None
        self._files = []

    def tearDown(self):
        for name in ("list_gate", "create_gate", "redirect_hold"):
            gate = getattr(self.mock, name, None)
            if gate is not None:
                gate.set()
        if self.client is not None:
            self.client.close()
        self.aid.stop()
        self.mock.stop()
        for path in self._files:
            try:
                os.remove(path)
            except OSError:
                pass
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def connect(self):
        self.client = Ndjson(self.aid.port)
        return self.client

    def assert_quiet(self, timeout=0.4):
        try:
            event = self.client.recv(timeout)
        except (socket.timeout, TimeoutError):
            return
        self.fail("unexpected event %r" % (event,))

    def _basic(self, password):
        return "Basic " + base64.b64encode(b"opencode:" + password.encode()).decode()

    def test_mock_rejects_missing_basic_auth(self):
        parsed = urllib.parse.urlparse(self.mock.url)
        conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=2)
        try:
            conn.request("GET", "/api/info")
            resp = conn.getresponse()
            body = resp.read()
            self.assertEqual(resp.status, 401)
            self.assertNotIn(self.password.encode(), body)
        finally:
            conn.close()

    def test_chat_uses_newest_session_and_basic_auth(self):
        os.environ["RGDS_AI_CONFIG"] = "/no/such/rgds-ai-config.json"
        os.environ["RGDS_AI_KEY"] = "legacy-key-should-not-appear"
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "hello"})
        self.assertEqual(client.recv(), {"ev": "start", "id": "r1"})
        prompts = self.mock.wait_calls(
            lambda call: call["method"] == "POST" and call["path"].endswith("/prompt"))
        self.assertEqual(len(prompts), 1)
        self.assertEqual(prompts[0]["path"], "/api/session/ses_new/prompt")
        self.assertEqual(prompts[0]["body"], {
            "text": "hello",
            "metadata": {"source": "rgds-handheld", "rid": "r1"},
        })
        self.assertEqual(prompts[0]["authorization"], self._basic(self.password))
        listed = self.mock.wait_calls(
            lambda call: call["method"] == "GET" and call["path"] == "/api/session")
        query = listed[0]["query"]
        self.assertEqual(query.get("directory"), [_WORKDIR])
        self.assertEqual(query.get("order"), ["desc"])
        self.assertEqual(query.get("limit"), ["10"])
        self.assertEqual(query.get("parentID"), ["null"])
        self.assertEqual(query.get("archived"), ["false"])
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="Hello"))
        self.mock.emit(_v2(
            "session.text.ended", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, text="Hello world"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["text"], "Hello")
        self.assertEqual(client.recv()["text"], " world")
        done = client.recv()
        self.assertEqual(done, {"ev": "done", "id": "r1"})
        blob = json.dumps(done)
        self.assertNotIn("legacy-key-should-not-appear", blob)
        self.assertNotIn(self.password, blob)

    def test_empty_list_creates_a_session(self):
        with self.mock.lock:
            self.mock.sessions.clear()
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "hi"})
        self.assertEqual(client.recv()["ev"], "start")
        created = self.mock.wait_calls(
            lambda call: call["method"] == "POST" and call["path"] == "/api/session")
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["body"], {"location": {"directory": _WORKDIR}})
        prompts = self.mock.wait_calls(lambda call: call["path"].endswith("/prompt"))
        self.assertEqual(prompts[0]["path"], "/api/session/ses_1/prompt")

    def test_cancel_interrupts_without_done(self):
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "stop"})
        self.assertEqual(client.recv()["ev"], "start")
        self.mock.wait_calls(lambda call: call["path"].endswith("/prompt"))
        client.send({"op": "cancel", "id": "r1"})
        hits = self.mock.wait_calls(lambda call: call["path"].endswith("/interrupt"))
        self.assertEqual(hits[0]["path"], "/api/session/ses_new/interrupt")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.execution.interrupted", sessionID="ses_new", reason="user"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        err = client.recv()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "cancelled")
        self.assertEqual(err["id"], "r1")
        self.assertTrue(err["retryable"])
        self.assert_quiet()

    def test_reset_rotates_the_session(self):
        client = self.connect()
        deadline = time.monotonic() + 3
        seen = None
        while time.monotonic() < deadline:
            client.send({"op": "status"})
            seen = client.recv()
            if seen.get("session_id") == "ses_new" and seen.get("net") == "ok":
                break
        else:
            self.fail("did not attach, last status %r" % (seen,))
        self.assertEqual(seen.get("version"), "2.4.0")
        client.send({"op": "reset"})
        reset = client.recv()
        self.assertEqual(reset["ev"], "status")
        self.assertTrue(reset["reset"])
        self.assertEqual(reset["session_id"], "ses_1")
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assert_quiet()

    def test_execution_failed_then_idle_has_no_done(self):
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "go"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="Hi"))
        self.mock.emit(_v2(
            "session.execution.failed", sessionID="ses_new",
            error={"type": "server", "message": "boom", "status": 500}))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["text"], "Hi")
        err = client.recv()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "server")
        self.assertEqual(err["partial"], "Hi")
        self.assertTrue(err["retryable"])
        self.assert_quiet()

    def test_pc_turn_on_the_shared_session(self):
        client = self.connect()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            client.send({"op": "status"})
            seen = client.recv()
            if seen.get("session_id") == "ses_new":
                break
        else:
            self.fail("did not attach")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.inbox.enqueued", sessionID="ses_new", inboxID="inb_pc",
            item={"type": "user", "payload": {"text": "from the desk", "metadata": {}}}))
        self.mock.emit(_v2(
            "session.tool.input.started", sessionID="ses_new",
            assistantMessageID="m1", id="t1", name="bash"))
        self.mock.emit(_v2(
            "session.tool.called", sessionID="ses_new",
            assistantMessageID="m1", id="t1", input={"command": "uname"}, executed=False))
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="Linux"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["ev"], "remote_user")
        self.assertEqual(client.recv()["ev"], "start")
        tool = client.recv()
        self.assertEqual(tool["ev"], "tool")
        self.assertEqual(tool["status"], "running")
        self.assertEqual(tool["call_id"], "t1")
        self.assertEqual(client.recv()["text"], "Linux")
        self.assertEqual(client.recv()["ev"], "done")

    def test_sse_drop_interrupts_the_open_turn_and_reconnects(self):
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "go"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="A"))
        self.assertEqual(client.recv()["text"], "A")
        with self.mock.lock:
            opens = self.mock.sse_opens
        self.mock.drop_sse()
        err = client.recv()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["id"], "r1")
        self.assertEqual(err["kind"], "interrupted")
        self.assertEqual(err["partial"], "A")
        self.assertTrue(err["retryable"])
        self.assertGreaterEqual(self.mock.wait_opens(opens + 1, timeout=4), opens + 1)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="B"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assert_quiet()

    def test_offline_when_opencode_is_down(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        os.environ["RGDS_OPENCODE_URL"] = "http://127.0.0.1:%d" % port
        client = self.connect()
        client.send({"op": "status"})
        status = client.recv()
        self.assertEqual(status["net"], "offline")
        self.assertNotIn(self.password, json.dumps(status))
        client.send({"op": "chat", "id": "r1", "text": "hi"})
        err = client.recv()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "offline")
        self.assertNotIn(self.password, json.dumps(err))

    def test_missing_password_is_auth_and_not_logged(self):
        os.environ.pop("OPENCODE_PASSWORD", None)
        os.environ["RGDS_OPENCODE_PASSWORD_FILE"] = "/tmp/rgds-aid-missing-password"
        captured = io.StringIO()
        old = sys.stderr
        sys.stderr = captured
        try:
            client = self.connect()
            client.send({"op": "chat", "id": "r1", "text": "hi"})
            err = client.recv()
        finally:
            sys.stderr = old
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "auth")
        self.assertEqual(err["msg"], "opencode password missing")
        self.assertNotIn(self.password, json.dumps(err))
        self.assertNotIn(self.password, captured.getvalue())

    def test_password_file_and_env_override_and_redaction(self):
        handle = tempfile.NamedTemporaryFile(delete=False)
        handle.write(b"file-secret-value\n")
        handle.close()
        self._files.append(handle.name)
        os.environ.pop("OPENCODE_PASSWORD", None)
        os.environ["RGDS_OPENCODE_PASSWORD_FILE"] = handle.name
        self.mock.password = "file-secret-value"
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "hi"})
        self.assertEqual(client.recv()["ev"], "start")
        prompts = self.mock.wait_calls(lambda call: call["path"].endswith("/prompt"))
        self.assertEqual(prompts[0]["authorization"], self._basic("file-secret-value"))
        client.close()
        self.client = None
        self.aid.stop()
        self.aid = AidServer()
        self.aid.start()
        os.environ["OPENCODE_PASSWORD"] = "env-secret-value"
        with open(handle.name, "wb") as out:
            out.write(b"file-secret-value\n")
        self.mock.password = "env-secret-value"
        client = self.connect()
        client.send({"op": "chat", "id": "r2", "text": "hi"})
        self.assertEqual(client.recv()["ev"], "start")
        self.mock.wait_calls(
            lambda call: call["path"].endswith("/prompt")
            and isinstance(call["body"], dict)
            and call["body"].get("metadata", {}).get("rid") == "r2")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["ev"], "done")
        self.mock.fail_prompt = True
        client.send({"op": "chat", "id": "r3", "text": "boom"})
        first = client.recv()
        if first["ev"] == "start":
            err = client.recv()
        else:
            err = first
        blob = json.dumps(err)
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "server")
        self.assertIn("[redacted]", err["msg"])
        self.assertNotIn("env-secret-value", blob)
        self.assertNotIn("file-secret-value", blob)
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assert_quiet()

    def test_wrong_password_is_auth(self):
        os.environ["OPENCODE_PASSWORD"] = "wrong-password"
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "hi"})
        err = client.recv()
        blob = json.dumps(err)
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "auth")
        self.assertNotIn("wrong-password", blob)
        self.assertNotIn(self.password, blob)

    def test_cancel_without_a_turn_does_nothing(self):
        client = self.connect()
        client.send({"op": "cancel", "id": "missing"})
        self.assert_quiet()
        hits = self.mock.wait_calls(lambda call: call["path"].endswith("/interrupt"), timeout=0.3)
        self.assertEqual(hits, [])

    def test_tool_pause_over_20s_keeps_the_sse_socket(self):
        # The old client aborted a quiet stream at 20s. A tool may stay quiet longer.
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "sleep"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.tool.input.started", sessionID="ses_new",
            assistantMessageID="m1", id="t1", name="bash"))
        self.mock.emit(_v2(
            "session.tool.called", sessionID="ses_new",
            assistantMessageID="m1", id="t1",
            input={"command": "sleep 25 && uname -a"}, executed=False))
        running = client.recv()
        self.assertEqual(running["status"], "running")
        with self.mock.lock:
            opens = self.mock.sse_opens
        time.sleep(21)
        with self.mock.lock:
            self.assertEqual(self.mock.sse_opens, opens)
        self.mock.emit(_v2(
            "session.tool.success", sessionID="ses_new",
            assistantMessageID="m1", id="t1",
            content="Linux", metadata={}, executed=True))
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="Linux"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        done_tool = client.recv(timeout=3)
        self.assertEqual(done_tool["status"], "completed")
        self.assertEqual(done_tool["call_id"], "t1")
        self.assertEqual(client.recv()["text"], "Linux")
        self.assertEqual(client.recv()["ev"], "done")

    def _wait_lists(self, count):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with self.mock.lock:
                if self.mock.lists_done >= count:
                    return
            time.sleep(0.02)
        self.fail("attach did not list sessions")

    def _deltas_until_done(self, client):
        parts = []
        while True:
            ev = client.recv()
            if ev["ev"] == "delta":
                parts.append(ev["text"])
                continue
            if ev["ev"] == "done":
                return "".join(parts)
            self.fail("unexpected event %r" % (ev,))

    def test_long_delta_remote_user_and_partial_stay_intact(self):
        body = "L" * (AID.MSG_LIMIT + 40)
        huge = "m" * (AID.MSG_LIMIT + 40)
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "long"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta=body))
        self.mock.emit(_v2(
            "session.execution.failed", sessionID="ses_new",
            error={"message": huge, "status": 500}))
        self.assertEqual(client.recv()["text"], body)
        err = client.recv()
        self.assertEqual(err["partial"], body)
        self.assertEqual(err["msg"], huge[:AID.MSG_LIMIT])
        self.assertEqual(len(err["msg"]), AID.MSG_LIMIT)
        self.mock.emit(_v2(
            "session.inbox.enqueued", sessionID="ses_new", inboxID="inb_long",
            item={"type": "user", "payload": {"text": body, "metadata": {}}}))
        remote = client.recv()
        self.assertEqual(remote["ev"], "remote_user")
        self.assertEqual(remote["text"], body)

    def test_password_split_across_deltas_is_redacted(self):
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "leak"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        secret = self.password
        cut = len(secret) // 2
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="x" + secret[:cut]))
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta=secret[cut:] + "y"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        blob = self._deltas_until_done(client)
        self.assertEqual(blob, "x[redacted]y")
        self.assertNotIn(secret, blob)
        token = base64.b64encode(b"opencode:" + secret.encode()).decode()
        cut = len(token) // 2
        client.send({"op": "chat", "id": "r2", "text": "token"})
        self.assertEqual(client.recv()["ev"], "start")
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m2", ordinal=0, delta="T" + token[:cut]))
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m2", ordinal=0, delta=token[cut:] + "Z"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        blob = self._deltas_until_done(client)
        self.assertEqual(blob, "T[redacted]Z")
        self.assertNotIn(token, blob)
        self.assertNotIn(secret, blob)

    def test_stop_returns_while_the_sse_peer_stays_open(self):
        extra = AID.OpenCodeClient()
        extra.start()
        try:
            deadline = time.monotonic() + 3
            while not extra.connected.is_set():
                if time.monotonic() > deadline:
                    self.fail("sse did not connect")
                time.sleep(0.02)
            started = time.monotonic()
            extra.stop()
            elapsed = time.monotonic() - started
        finally:
            extra.stop()
        self.assertLess(elapsed, 1.0)
        self.assertFalse(self.mock.closed)
        with self.mock.lock:
            self.assertGreaterEqual(len(self.mock.sse_queues), 1)

    def test_short_reads_do_not_drop_the_tcp_connection(self):
        client = self.connect()
        self.mock.fault = "info"
        client.send({"op": "status"})
        status = client.recv()
        self.assertEqual(status["net"], "offline")
        client.send({"op": "status"})
        status = client.recv()
        self.assertEqual(status["net"], "ok")
        self.mock.fault = "create"
        client.send({"op": "reset"})
        err = client.recv()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "server")
        client.send({"op": "status"})
        status = client.recv()
        self.assertEqual(status["net"], "ok")
        self.assertTrue(status.get("session_id"))

    def test_redirect_is_refused(self):
        self.mock.redirect_status = 302
        self.mock.redirect_hold = threading.Event()
        self.mock.redirect_entered = threading.Event()
        client = self.connect()
        try:
            client.send({"op": "chat", "id": "r1", "text": "hi"})
            err = client.recv(timeout=2)
        finally:
            self.mock.redirect_hold.set()
            self.mock.redirect_status = 0
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "server")
        self.assertIn("302", err["msg"])
        self.assertNotIn(self.password, json.dumps(err))
        calls = self.mock.wait_calls(lambda call: "stolen" in call["path"], timeout=0.2)
        self.assertEqual(calls, [])
        client.send({"op": "status"})
        self.assertEqual(client.recv()["net"], "ok")

    def test_pc_prompt_is_queued_until_the_handheld_turn_finishes(self):
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "handheld"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self.mock.emit(_v2(
            "session.inbox.enqueued", sessionID="ses_new", inboxID="inb_pc",
            item={"type": "user", "payload": {"text": "from the desk", "metadata": {}}}))
        self.assert_quiet(0.3)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m1", ordinal=0, delta="Hi"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["text"], "Hi")
        self.assertEqual(client.recv(), {"ev": "done", "id": "r1"})
        remote = client.recv()
        self.assertEqual(remote["ev"], "remote_user")
        self.assertEqual(remote["text"], "from the desk")
        self.assertEqual(client.recv(), {"ev": "start", "id": remote["id"]})
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m2", ordinal=0, delta="PC"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["text"], "PC")
        self.assertEqual(client.recv()["ev"], "done")

    def test_cancel_during_lookup_sends_no_prompt(self):
        self.mock.list_gate = threading.Event()
        self.mock.list_ready = threading.Event()
        client = self.connect()
        try:
            client.send({"op": "chat", "id": "r1", "text": "hi"})
            self.assertTrue(self.mock.list_ready.wait(2))
            client.send({"op": "cancel", "id": "r1"})
            self.mock.list_gate.set()
            err = client.recv(timeout=2)
        finally:
            self.mock.list_gate.set()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["kind"], "cancelled")
        self.assertEqual(err["id"], "r1")
        self.assert_quiet(0.3)
        prompts = self.mock.wait_calls(lambda call: call["path"].endswith("/prompt"), timeout=0.3)
        self.assertEqual(prompts, [])

    def test_cancel_then_new_chat_ignores_the_old_interrupt(self):
        client = self.connect()
        client.send({"op": "chat", "id": "r1", "text": "first"})
        self.assertEqual(client.recv()["ev"], "start")
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        client.send({"op": "cancel", "id": "r1"})
        client.send({"op": "chat", "id": "r2", "text": "second"})
        seen = []
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                ev = client.recv(timeout=0.4)
            except (socket.timeout, TimeoutError):
                continue
            seen.append(ev)
            if ev.get("ev") == "start" and ev.get("id") == "r2":
                break
        else:
            self.fail("no start for r2, saw %r" % (seen,))
        self.assertTrue(any(
            ev.get("id") == "r1" and ev.get("kind") == "cancelled" for ev in seen))
        self.mock.wait_calls(
            lambda call: call["path"].endswith("/prompt")
            and isinstance(call["body"], dict)
            and call["body"].get("metadata", {}).get("rid") == "r2")
        self.mock.emit(_v2(
            "session.execution.interrupted", sessionID="ses_new", reason="user"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assert_quiet(0.3)
        self.mock.emit(_v2(
            "session.text.delta", sessionID="ses_new",
            assistantMessageID="m2", ordinal=0, delta="B"))
        self.mock.emit(_v2("session.idle", sessionID="ses_new"))
        self.assertEqual(client.recv()["text"], "B")
        self.assertEqual(client.recv(), {"ev": "done", "id": "r2"})

    def test_reset_is_not_reverted_by_an_inflight_chat(self):
        with self.mock.lock:
            self.mock.sessions.clear()
        self.mock.create_gate = threading.Event()
        self.mock.create_entered = threading.Event()
        client = self.connect()
        try:
            self.assertGreaterEqual(self.mock.wait_opens(1), 1)
            client.send({"op": "chat", "id": "r1", "text": "late"})
            self.assertTrue(self.mock.create_entered.wait(2))
            client.send({"op": "reset"})
            reset = client.recv(timeout=2)
            self.assertEqual(reset["ev"], "status")
            self.assertTrue(reset["reset"])
            sid = reset["session_id"]
            self.mock.create_gate.set()
            err = client.recv(timeout=2)
        finally:
            self.mock.create_gate.set()
        self.assertEqual(err["ev"], "error")
        self.assertEqual(err["id"], "r1")
        self.assertEqual(err["kind"], "interrupted")
        client.send({"op": "status"})
        status = client.recv()
        self.assertEqual(status["session_id"], sid)
        self.assertEqual(status["net"], "ok")
        prompts = self.mock.wait_calls(lambda call: call["path"].endswith("/prompt"), timeout=0.3)
        self.assertEqual(prompts, [])

    def test_server_connected_adopts_a_late_session(self):
        with self.mock.lock:
            self.mock.sessions.clear()
        client = self.connect()
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self._wait_lists(2)
        client.send({"op": "status"})
        before = client.recv()
        self.assertIsNone(before.get("session_id"))
        with self.mock.lock:
            self.mock.sessions.insert(0, {"id": "ses_late", "directory": _WORKDIR})
        self.mock.emit({"id": "evt", "type": "server.connected", "data": {}})
        deadline = time.monotonic() + 3
        seen = None
        while time.monotonic() < deadline:
            client.send({"op": "status"})
            seen = client.recv()
            if seen.get("session_id") == "ses_late" and seen.get("net") == "ok":
                break
        else:
            self.fail("did not adopt on server.connected, last %r" % (seen,))

    def test_inbox_adopts_a_session_when_none_is_attached(self):
        with self.mock.lock:
            self.mock.sessions.clear()
        client = self.connect()
        self.assertGreaterEqual(self.mock.wait_opens(1), 1)
        self._wait_lists(2)
        client.send({"op": "status"})
        before = client.recv()
        self.assertIsNone(before.get("session_id"))
        with self.mock.lock:
            self.mock.sessions.insert(0, {"id": "ses_late", "directory": _WORKDIR})
        self.mock.emit(_v2(
            "session.inbox.enqueued", sessionID="ses_late", inboxID="inb_late",
            item={"type": "user", "payload": {"text": "from the desk", "metadata": {}}}))
        remote = client.recv(timeout=3)
        self.assertEqual(remote["ev"], "remote_user")
        self.assertEqual(remote["text"], "from the desk")
        self.assertEqual(client.recv()["ev"], "start")


if __name__ == "__main__":
    unittest.main()
