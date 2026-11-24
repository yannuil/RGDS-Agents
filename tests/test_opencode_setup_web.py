import base64
import http.server
import importlib.util
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SETUP_SCRIPT = REPO_ROOT / "opencode" / "opencode-setup-web.py"
SERVICE_SCRIPT = REPO_ROOT / "opencode" / "opencode-service.sh"


def load_setup_module():
    spec = importlib.util.spec_from_file_location("opencode_setup_web", SETUP_SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


setup_mod = load_setup_module()


def pick_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_request(
    url: str,
    *,
    method: str = "GET",
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, str]:
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        with exc:
            return exc.code, exc.read().decode("utf-8")


class PureFunctionsTest(unittest.TestCase):
    def test_generate_token_uses_unambiguous_alphabet(self) -> None:
        token = setup_mod.generate_token()
        self.assertEqual(len(token), 6)
        for ch in token:
            self.assertIn(ch, setup_mod.TOKEN_ALPHABET)
            self.assertNotIn(ch, "01IO")
        tokens = {setup_mod.generate_token() for _ in range(20)}
        self.assertGreater(len(tokens), 1)

    def test_parse_and_validate_form_valid_builtin(self) -> None:
        inp = setup_mod.parse_and_validate_form(
            {
                "token": "ab3k9m",
                "provider_id": "anthropic",
                "model_id": "claude-sonnet-4-5",
                "api_key": "sk-ant-test-123",
                "base_url": "",
            },
            expected_token="AB3K9M",
        )
        self.assertEqual(inp.token, "AB3K9M")
        self.assertEqual(inp.provider_id, "anthropic")
        self.assertEqual(inp.model_id, "claude-sonnet-4-5")
        self.assertEqual(inp.api_key, "sk-ant-test-123")
        self.assertEqual(inp.base_url, "")

    def test_parse_and_validate_form_valid_with_base_url(self) -> None:
        inp = setup_mod.parse_and_validate_form(
            {
                "token": "ZX7P2Q",
                "provider_id": "deepseek",
                "model_id": "deepseek-chat",
                "api_key": "sk-ds-999",
                "base_url": "https://api.deepseek.com/v1",
            },
            expected_token="ZX7P2Q",
        )
        self.assertEqual(inp.base_url, "https://api.deepseek.com/v1")

    def test_parse_and_validate_form_rejects_bad_token(self) -> None:
        with self.assertRaises(setup_mod.AuthError):
            setup_mod.parse_and_validate_form(
                {
                    "token": "WRONG1",
                    "provider_id": "openai",
                    "model_id": "gpt-5.4",
                    "api_key": "sk-1",
                },
                expected_token="RIGHT2",
            )
        with self.assertRaises(setup_mod.AuthError):
            setup_mod.parse_and_validate_form(
                {
                    "token": "",
                    "provider_id": "openai",
                    "model_id": "gpt-5.4",
                    "api_key": "sk-1",
                },
                expected_token="RIGHT2",
            )

    def test_parse_and_validate_form_rejects_invalid_fields(self) -> None:
        base = {
            "token": "TOKEN2",
            "provider_id": "openai",
            "model_id": "gpt-5.4",
            "api_key": "sk-1",
            "base_url": "",
        }
        bad_cases = [
            {"provider_id": ""},
            {"provider_id": "OpenAI"},
            {"provider_id": "-bad"},
            {"provider_id": "bad/slash"},
            {"model_id": ""},
            {"model_id": "bad\nmodel"},
            {"api_key": ""},
            {"api_key": "bad\nkey"},
            {"base_url": "ftp://example.com/v1"},
            {"base_url": "https://"},
            {"base_url": "not-a-url"},
            {"provider_id": "custom", "base_url": ""},
        ]
        for overrides in bad_cases:
            form = dict(base, **overrides)
            with self.subTest(overrides=overrides):
                with self.assertRaises(setup_mod.ValidationError):
                    setup_mod.parse_and_validate_form(form, expected_token="TOKEN2")

    def test_build_opencode_config_v2_preserves_existing_and_sets_base_url(self) -> None:
        existing = {
            "timezone": "UTC",
            "permission": "allow",
            "providers": {
                "other": {"settings": {"baseURL": "https://other.example/v1"}},
            },
        }
        inp = setup_mod.SetupInput(
            token="TOKEN2",
            provider_id="deepseek",
            model_id="deepseek-chat",
            api_key="sk-secret",
            base_url="https://api.deepseek.com/v1",
        )
        cfg = setup_mod.build_opencode_config(inp, existing)
        self.assertEqual(cfg["model"], "deepseek/deepseek-chat")
        self.assertEqual(cfg["update"], "disable")
        self.assertNotIn("permission", cfg)
        self.assertEqual(
            cfg["permissions"],
            [{"action": "*", "resource": "*", "effect": "allow"}],
        )
        self.assertEqual(cfg["timezone"], "UTC")
        self.assertIn("other", cfg["providers"])
        self.assertEqual(cfg["providers"]["deepseek"]["package"], "@ai-sdk/openai-compatible")
        self.assertEqual(
            cfg["providers"]["deepseek"]["settings"]["baseURL"],
            "https://api.deepseek.com/v1",
        )
        self.assertEqual(
            cfg["providers"]["deepseek"]["models"]["deepseek-chat"],
            {"name": "deepseek-chat"},
        )
        self.assertNotIn("deepseek", existing["providers"])

    def test_build_opencode_config_omits_providers_block_without_base_url(self) -> None:
        inp = setup_mod.SetupInput(
            token="TOKEN2",
            provider_id="anthropic",
            model_id="claude-sonnet-4-5",
            api_key="sk-ant",
            base_url="",
        )
        cfg = setup_mod.build_opencode_config(inp, None)
        self.assertEqual(cfg["model"], "anthropic/claude-sonnet-4-5")
        self.assertEqual(cfg["update"], "disable")
        self.assertEqual(
            cfg["permissions"],
            [{"action": "*", "resource": "*", "effect": "allow"}],
        )
        self.assertNotIn("providers", cfg)

    def test_build_credential_payload_v2(self) -> None:
        inp = setup_mod.SetupInput(
            token="TOKEN2",
            provider_id="openai",
            model_id="gpt-5.4",
            api_key="sk-oai-key",
            base_url="",
        )
        self.assertEqual(
            setup_mod.build_credential_payload(inp),
            {
                "integrationID": "openai",
                "value": {"type": "key", "key": "sk-oai-key"},
                "activate": True,
            },
        )

    def test_atomic_write_json_sets_mode_600(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            target = Path(td) / "nested" / "opencode.json"
            setup_mod.atomic_write_json(target, {"k": "v"}, mode=0o600)
            self.assertEqual(json.loads(target.read_text(encoding="utf-8")), {"k": "v"})
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_redact_secrets(self) -> None:
        self.assertEqual(
            setup_mod.redact_secrets("failed with sk-12345 and srv-pw", "sk-12345", "srv-pw"),
            "failed with [REDACTED] and [REDACTED]",
        )
        self.assertEqual(setup_mod.redact_secret("unchanged", ""), "unchanged")


class _MockOpenCodeV2Server(http.server.HTTPServer):
    def __init__(self, address: tuple[str, int], password: str) -> None:
        self.expected_auth = "Basic " + base64.b64encode(
            f"opencode:{password}".encode("utf-8")
        ).decode("ascii")
        self.credentials: list[dict] = []
        self.info_hits = 0
        self.fail_credential_status: int | None = None
        super().__init__(address, _MockOpenCodeV2Handler)


class _MockOpenCodeV2Handler(http.server.BaseHTTPRequestHandler):
    server: _MockOpenCodeV2Server

    def log_message(self, format: str, *args) -> None:
        pass

    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == self.server.expected_auth

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"_tag": "UnauthorizedError", "message": "Authentication required"})
            return
        if self.path == "/api/info":
            self.server.info_hits += 1
            self._send_json(
                200,
                {"version": "2.4.0", "pid": os.getpid(), "urls": [], "paths": {"tmp": "/tmp"}},
            )
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        if not self._authorized():
            self._send_json(401, {"_tag": "UnauthorizedError", "message": "Authentication required"})
            return
        if self.path == "/api/credential":
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            payload = json.loads(raw)
            if self.server.fail_credential_status is not None:
                self._send_json(
                    self.server.fail_credential_status,
                    {"error": f"rejected {payload['value']['key']}"},
                )
                return
            self.server.credentials.append(payload)
            self._send_json(
                200,
                {
                    "data": {
                        "id": "cred_test1",
                        "integrationID": payload["integrationID"],
                        "label": payload["integrationID"],
                        "active": True,
                        "value": payload["value"],
                    }
                },
            )
            return
        self.send_response(404)
        self.end_headers()


class LiveWizardHTTPTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.data_root = self.root / "userdata-opencode"
        self.data_root.mkdir(parents=True, exist_ok=True)
        self.server_password = "srv-secret-password-42"
        self.password_file = self.data_root / "server.password"
        self.password_file.write_text(f"{self.server_password}\n", encoding="utf-8")
        os.chmod(self.password_file, 0o600)

        self.status_file = self.root / "status.json"
        self.service_log = self.root / "service-calls.log"
        self.service_script = self.root / "fake-service.sh"
        self.service_script.write_text(
            f"#!/bin/sh\necho \"$@\" >> '{self.service_log}'\nexit 0\n",
            encoding="utf-8",
        )
        os.chmod(self.service_script, 0o755)

        self.api_server = _MockOpenCodeV2Server(("127.0.0.1", 0), self.server_password)
        self.api_port = self.api_server.server_address[1]
        self.api_thread = threading.Thread(target=self.api_server.serve_forever, daemon=True)
        self.api_thread.start()

    def tearDown(self) -> None:
        self.api_server.shutdown()
        self.api_server.server_close()
        self.tmpdir.cleanup()

    def _start_wizard(self, token: str = "PAIR42", service_cmd: Path | None = None):
        args = setup_mod.build_arg_parser().parse_args(
            [
                "--host",
                "127.0.0.1",
                "--port",
                "0",
                "--data-root",
                str(self.data_root),
                "--service-cmd",
                str(service_cmd or self.service_script),
                "--server-url",
                f"http://127.0.0.1:{self.api_port}",
                "--password-file",
                str(self.password_file),
                "--status-file",
                str(self.status_file),
                "--token",
                token,
            ]
        )
        thread = threading.Thread(target=setup_mod.run_server, args=(args,), daemon=True)
        thread.start()
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if self.status_file.is_file():
                try:
                    info = json.loads(self.status_file.read_text(encoding="utf-8"))
                    return thread, info
                except json.JSONDecodeError:
                    pass
            time.sleep(0.02)
        self.fail("wizard did not write status file in time")

    def test_full_wizard_flow_form_and_errors(self) -> None:
        config_path = self.data_root / "config" / "opencode" / "opencode.json"
        setup_mod.atomic_write_json(config_path, {"timezone": "UTC"}, mode=0o600)

        status_unauth, _ = http_request(f"http://127.0.0.1:{self.api_port}/api/info")
        self.assertEqual(status_unauth, 401)

        thread, info = self._start_wizard(token="AB3K9M")
        base_url = info["url"].rstrip("/")
        self.assertEqual(info["token"], "AB3K9M")

        status, page = http_request(f"{base_url}/")
        self.assertEqual(status, 200)
        self.assertIn("RGDS OpenCode Setup", page)
        self.assertNotIn(self.server_password, page)

        bad_token_body = urllib.parse.urlencode(
            {
                "token": "ZZZZZZ",
                "provider_id": "openai",
                "model_id": "gpt-5.4",
                "api_key": "sk-nope",
            }
        ).encode("utf-8")
        status, _ = http_request(
            f"{base_url}/setup",
            method="POST",
            data=bad_token_body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 403)
        self.assertEqual(self.api_server.credentials, [])

        bad_url_body = urllib.parse.urlencode(
            {
                "token": "AB3K9M",
                "provider_id": "custom",
                "model_id": "my-model",
                "api_key": "sk-nope",
                "base_url": "ftp://invalid.example",
            }
        ).encode("utf-8")
        status, _ = http_request(
            f"{base_url}/setup",
            method="POST",
            data=bad_url_body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 400)

        good_body = urllib.parse.urlencode(
            {
                "token": "ab3k9m",
                "provider_id": "deepseek",
                "model_id": "deepseek-chat",
                "api_key": "sk-new-deepseek-key",
                "base_url": "https://api.deepseek.com/v1",
            }
        ).encode("utf-8")
        status, resp_html = http_request(
            f"{base_url}/setup",
            method="POST",
            data=good_body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 200)
        self.assertIn("deepseek/deepseek-chat", resp_html)
        self.assertNotIn("sk-new-deepseek-key", resp_html)

        thread.join(timeout=5.0)
        self.assertFalse(thread.is_alive(), "wizard should exit after successful setup")
        self.assertFalse(self.status_file.exists(), "status file should be removed on shutdown")

        saved_cfg = json.loads(config_path.read_text(encoding="utf-8"))
        self.assertEqual(saved_cfg["timezone"], "UTC")
        self.assertEqual(saved_cfg["model"], "deepseek/deepseek-chat")
        self.assertEqual(saved_cfg["update"], "disable")
        self.assertEqual(
            saved_cfg["permissions"],
            [{"action": "*", "resource": "*", "effect": "allow"}],
        )
        self.assertEqual(
            saved_cfg["providers"]["deepseek"]["settings"]["baseURL"],
            "https://api.deepseek.com/v1",
        )
        self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
        self.assertFalse((self.data_root / "share" / "opencode" / "auth.json").exists())

        self.assertEqual(self.api_server.info_hits, 1)
        self.assertEqual(
            self.api_server.credentials,
            [
                {
                    "integrationID": "deepseek",
                    "value": {"type": "key", "key": "sk-new-deepseek-key"},
                    "activate": True,
                }
            ],
        )
        self.assertEqual(self.service_log.read_text(encoding="utf-8").strip(), "restart")

    def test_json_submission_and_secret_redaction_on_failures(self) -> None:
        fail_script = self.root / "fail-service.sh"
        fail_script.write_text(
            f"#!/bin/sh\necho 'boom sk-super-secret-999 and {self.server_password}' >&2\nexit 1\n",
            encoding="utf-8",
        )
        os.chmod(fail_script, 0o755)

        thread, info = self._start_wizard(token="JSON77", service_cmd=fail_script)
        base_url = info["url"].rstrip("/")

        payload = json.dumps(
            {
                "token": "JSON77",
                "provider_id": "openai",
                "model_id": "gpt-5.4",
                "api_key": "sk-super-secret-999",
            }
        ).encode("utf-8")
        status, body = http_request(
            f"{base_url}/setup",
            method="POST",
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        self.assertEqual(status, 500)
        parsed = json.loads(body)
        self.assertFalse(parsed["ok"])
        self.assertNotIn("sk-super-secret-999", parsed["error"])
        self.assertNotIn(self.server_password, parsed["error"])
        self.assertIn("[REDACTED]", parsed["error"])

        fail_script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.api_server.fail_credential_status = 400
        status, body = http_request(
            f"{base_url}/setup",
            method="POST",
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        self.assertEqual(status, 500)
        parsed = json.loads(body)
        self.assertFalse(parsed["ok"])
        self.assertNotIn("sk-super-secret-999", parsed["error"])
        self.assertIn("[REDACTED]", parsed["error"])

        self.api_server.fail_credential_status = None
        status, body = http_request(
            f"{base_url}/setup",
            method="POST",
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True, "model": "openai/gpt-5.4"})
        thread.join(timeout=5.0)
        self.assertFalse(thread.is_alive())


class ServiceScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.port = pick_free_port()
        self.data_root = self.root / "data"
        self.workdir = self.root / "workdir"
        self.workdir.mkdir()
        self.pid_file = self.root / "opencode.pid"
        self.log_file = self.root / "opencode.log"

        self.fake_bin = self.root / "opencode"
        self.fake_bin.write_text(
            f"""#!{sys.executable}
import base64
import http.server
import os
import signal
import sys

args = sys.argv[1:]
assert args[0] == "serve", f"unexpected args: {{args}}"
host = args[args.index("--hostname") + 1]
port = int(args[args.index("--port") + 1])
pw = os.environ.get("OPENCODE_PASSWORD", "")
assert pw, "OPENCODE_PASSWORD must be set"
expected_auth = "Basic " + base64.b64encode(("opencode:" + pw).encode("utf-8")).decode("ascii")

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass
    def do_GET(self):
        if self.headers.get("Authorization") != expected_auth:
            self.send_response(401)
            self.end_headers()
            return
        if self.path == "/api/info":
            body = b'{{"version":"2.4.0","pid":1,"urls":[],"paths":{{"tmp":"/tmp"}}}}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

srv = http.server.HTTPServer((host, port), H)
def _stop(_sig, _frame):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, _stop)
try:
    srv.serve_forever()
except SystemExit:
    srv.server_close()
""",
            encoding="utf-8",
        )
        os.chmod(self.fake_bin, 0o755)

        self.env = os.environ.copy()
        self.env.update(
            {
                "OPENCODE_BIN": str(self.fake_bin),
                "OPENCODE_DATA_ROOT": str(self.data_root),
                "OPENCODE_WORKDIR": str(self.workdir),
                "OPENCODE_HOST": "127.0.0.1",
                "OPENCODE_PORT": str(self.port),
                "OPENCODE_PID_FILE": str(self.pid_file),
                "OPENCODE_LOG_FILE": str(self.log_file),
            }
        )

    def tearDown(self) -> None:
        subprocess.run(
            [str(SERVICE_SCRIPT), "stop"],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.tmpdir.cleanup()

    def _run_service(self, action: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SERVICE_SCRIPT), action],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_lifecycle_idempotency_password_and_stale_pid_handling(self) -> None:
        st0 = self._run_service("status")
        self.assertEqual(st0.returncode, 1)
        self.assertIn("stopped", st0.stdout)

        start1 = self._run_service("start")
        self.assertEqual(start1.returncode, 0, msg=start1.stderr)
        self.assertTrue(self.pid_file.is_file())
        pid1 = self.pid_file.read_text(encoding="utf-8").strip()
        self.assertTrue(pid1.isdigit())

        pw_file = self.data_root / "server.password"
        self.assertTrue(pw_file.is_file())
        self.assertEqual(stat.S_IMODE(pw_file.stat().st_mode), 0o600)
        pw1 = pw_file.read_text(encoding="utf-8").strip()
        self.assertGreaterEqual(len(pw1), 32)
        self.assertNotIn(pw1, start1.stdout)
        self.assertNotIn(pw1, start1.stderr)

        self.assertEqual(stat.S_IMODE(self.data_root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.data_root / "share" / "opencode").stat().st_mode), 0o700)

        agents_dest = self.data_root / "config" / "opencode" / "AGENTS.md"
        self.assertTrue(agents_dest.is_file())
        agents_dest.write_text("# user custom agents\n", encoding="utf-8")

        start2 = self._run_service("start")
        self.assertEqual(start2.returncode, 0, msg=start2.stderr)
        self.assertEqual(self.pid_file.read_text(encoding="utf-8").strip(), pid1)

        st1 = self._run_service("status")
        self.assertEqual(st1.returncode, 0, msg=st1.stderr)
        self.assertIn("running", st1.stdout)
        self.assertIn(pid1, st1.stdout)

        restarted = self._run_service("restart")
        self.assertEqual(restarted.returncode, 0, msg=restarted.stderr)
        pid2 = self.pid_file.read_text(encoding="utf-8").strip()
        self.assertNotEqual(pid2, pid1)
        self.assertEqual(pw_file.read_text(encoding="utf-8").strip(), pw1)
        self.assertEqual(agents_dest.read_text(encoding="utf-8"), "# user custom agents\n")

        stop1 = self._run_service("stop")
        self.assertEqual(stop1.returncode, 0, msg=stop1.stderr)
        self.assertFalse(self.pid_file.exists())

        stop2 = self._run_service("stop")
        self.assertEqual(stop2.returncode, 0, msg=stop2.stderr)

        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            self.pid_file.write_text(f"{sleeper.pid}\n", encoding="utf-8")
            st_stale = self._run_service("status")
            self.assertEqual(st_stale.returncode, 1)

            stop_stale = self._run_service("stop")
            self.assertEqual(stop_stale.returncode, 0)
            self.assertFalse(self.pid_file.exists())
            self.assertIsNone(sleeper.poll(), "stop must not kill an unrelated process")

            self.pid_file.write_text("999999\n", encoding="utf-8")
            start_after_stale = self._run_service("start")
            self.assertEqual(start_after_stale.returncode, 0, msg=start_after_stale.stderr)
            self.assertNotEqual(self.pid_file.read_text(encoding="utf-8").strip(), "999999")
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)

    def test_start_fails_fast_when_binary_crashes(self) -> None:
        crash_bin = self.root / "opencode-crash"
        crash_bin.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        os.chmod(crash_bin, 0o755)
        env = dict(self.env, OPENCODE_BIN=str(crash_bin))
        t0 = time.monotonic()
        res = subprocess.run(
            [str(SERVICE_SCRIPT), "start"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        elapsed = time.monotonic() - t0
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(self.pid_file.exists())
        self.assertLess(elapsed, 5.0)


if __name__ == "__main__":
    unittest.main()
