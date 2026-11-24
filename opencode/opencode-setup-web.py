#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import copy
import hmac
import html
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any


TOKEN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
PROVIDER_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SETUP_TOKEN_RE = re.compile(r"^[A-Za-z0-9]{6}$")
MAX_BODY_BYTES = 65536


class AuthError(ValueError):
    pass


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class ProviderPreset:
    id: str
    label: str
    default_model: str
    default_base_url: str
    needs_base_url: bool
    package: str | None


PROVIDERS: tuple[ProviderPreset, ...] = (
    ProviderPreset(
        id="anthropic",
        label="Anthropic",
        default_model="claude-sonnet-4-5",
        default_base_url="",
        needs_base_url=False,
        package=None,
    ),
    ProviderPreset(
        id="openai",
        label="OpenAI",
        default_model="gpt-5.4",
        default_base_url="",
        needs_base_url=False,
        package=None,
    ),
    ProviderPreset(
        id="deepseek",
        label="DeepSeek",
        default_model="deepseek-chat",
        default_base_url="https://api.deepseek.com/v1",
        needs_base_url=True,
        package="@ai-sdk/openai-compatible",
    ),
    ProviderPreset(
        id="minimax",
        label="MiniMax",
        default_model="MiniMax-M3",
        default_base_url="https://api.minimax.cn/v1",
        needs_base_url=True,
        package="@ai-sdk/openai-compatible",
    ),
    ProviderPreset(
        id="openrouter",
        label="OpenRouter",
        default_model="anthropic/claude-sonnet-4.5",
        default_base_url="https://openrouter.ai/api/v1",
        needs_base_url=True,
        package="@ai-sdk/openai-compatible",
    ),
    ProviderPreset(
        id="custom",
        label="Custom (OpenAI-compatible)",
        default_model="",
        default_base_url="",
        needs_base_url=True,
        package="@ai-sdk/openai-compatible",
    ),
)

PROVIDER_BY_ID: dict[str, ProviderPreset] = {p.id: p for p in PROVIDERS}


@dataclass(frozen=True)
class SetupInput:
    token: str
    provider_id: str
    model_id: str
    api_key: str
    base_url: str


def generate_token(length: int = 6) -> str:
    if length < 1:
        raise ValueError("token length must be positive")
    return "".join(secrets.choice(TOKEN_ALPHABET) for _ in range(length))


def parse_and_validate_form(form: dict[str, str], expected_token: str) -> SetupInput:
    token = str(form.get("token", "")).strip()
    if not token or not hmac.compare_digest(token.upper(), expected_token.strip().upper()):
        raise AuthError("Invalid pairing token.")

    provider_id = str(form.get("provider_id", "")).strip()
    if not provider_id or not PROVIDER_ID_RE.match(provider_id):
        raise ValidationError("Provider ID must match [a-z0-9][a-z0-9._-]*.")

    model_id = str(form.get("model_id", "")).strip()
    if not model_id or any(ord(ch) < 32 for ch in model_id):
        raise ValidationError("Model ID is required.")

    api_key = str(form.get("api_key", "")).strip()
    if not api_key or "\n" in api_key or "\r" in api_key:
        raise ValidationError("API key is required.")

    base_url = str(form.get("base_url", "")).strip()
    preset = PROVIDER_BY_ID.get(provider_id)
    if preset and preset.needs_base_url and not base_url:
        if preset.default_base_url:
            base_url = preset.default_base_url
        else:
            raise ValidationError("Base URL is required for this provider.")
    if base_url:
        parsed = urllib.parse.urlparse(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise ValidationError("Base URL must be an http or https URL with a hostname.")

    return SetupInput(
        token=token.upper(),
        provider_id=provider_id,
        model_id=model_id,
        api_key=api_key,
        base_url=base_url,
    )


def build_opencode_config(
    inp: SetupInput,
    existing: dict[str, Any] | None = None,
) -> dict[str, Any]:
    cfg: dict[str, Any] = copy.deepcopy(existing) if isinstance(existing, dict) else {}
    cfg.pop("permission", None)
    cfg["model"] = f"{inp.provider_id}/{inp.model_id}"
    cfg["update"] = "disable"
    cfg["permissions"] = [{"action": "*", "resource": "*", "effect": "allow"}]

    if inp.base_url:
        providers = cfg.get("providers")
        if not isinstance(providers, dict):
            providers = {}
            cfg["providers"] = providers

        existing_entry = providers.get(inp.provider_id)
        entry: dict[str, Any] = dict(existing_entry) if isinstance(existing_entry, dict) else {}
        preset = PROVIDER_BY_ID.get(inp.provider_id)
        entry["package"] = (
            preset.package if preset and preset.package else "@ai-sdk/openai-compatible"
        )

        existing_settings = entry.get("settings")
        settings: dict[str, Any] = (
            dict(existing_settings) if isinstance(existing_settings, dict) else {}
        )
        settings["baseURL"] = inp.base_url
        entry["settings"] = settings

        existing_models = entry.get("models")
        models: dict[str, Any] = dict(existing_models) if isinstance(existing_models, dict) else {}
        models.setdefault(inp.model_id, {"name": inp.model_id})
        entry["models"] = models

        providers[inp.provider_id] = entry

    return cfg


def build_credential_payload(inp: SetupInput) -> dict[str, Any]:
    return {
        "integrationID": inp.provider_id,
        "value": {"type": "key", "key": inp.api_key},
        "activate": True,
    }


def basic_auth_header(password: str) -> str:
    raw = f"opencode:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def atomic_write_bytes(path: Path, raw: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.parent / f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        try:
            view = memoryview(raw)
            written = 0
            while written < len(raw):
                written += os.write(fd, view[written:])
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def atomic_write_json(path: Path, payload: dict[str, Any], mode: int = 0o600) -> None:
    raw = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write_bytes(path, raw, mode)


def redact_secret(text: str, secret: str) -> str:
    if not secret:
        return text
    return text.replace(secret, "[REDACTED]")


def redact_secrets(text: str, *secret_values: str) -> str:
    out = text
    # Longer values first so a Basic token is removed before the password it encodes.
    for secret in sorted((s for s in secret_values if s), key=len, reverse=True):
        out = out.replace(secret, "[REDACTED]")
    return out


def load_existing_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def read_server_password(path: Path) -> str:
    try:
        pw = path.read_text(encoding="utf-8").splitlines()[0].strip()
    except (OSError, IndexError) as exc:
        raise RuntimeError(f"Server password file unreadable: {path}") from exc
    if not pw:
        raise RuntimeError(f"Server password file is empty: {path}")
    return pw


def detect_lan_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 80))
        ip = sock.getsockname()[0]
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    finally:
        sock.close()
    return "rgds.local"


def render_setup_page(error: str | None = None) -> str:
    presets_json = json.dumps(
        {
            p.id: {
                "default_model": p.default_model,
                "default_base_url": p.default_base_url,
                "needs_base_url": p.needs_base_url,
            }
            for p in PROVIDERS
        }
    )
    options_html = "\n".join(
        f'<option value="{html.escape(p.id)}">{html.escape(p.label)}</option>'
        for p in PROVIDERS
    )
    error_banner = (
        f'<div class="alert error">{html.escape(error)}</div>' if error else ""
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RGDS OpenCode Setup</title>
<style>
  :root {{
    color-scheme: dark;
    --bg: #111317;
    --card: #1a1e25;
    --fg: #eef1f6;
    --muted: #98a2b3;
    --border: #2e3542;
    --accent: #3b82f6;
    --accent-hover: #2563eb;
    --err-bg: #3b171b;
    --err-fg: #fecaca;
    --ok-bg: #122d1f;
    --ok-fg: #bbf7d0;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 20px 14px 36px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: var(--bg);
    color: var(--fg);
  }}
  main {{
    max-width: 440px;
    margin: 0 auto;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
  }}
  h1 {{ margin: 0 0 6px; font-size: 1.35rem; }}
  p {{ margin: 0 0 18px; color: var(--muted); font-size: 0.92rem; line-height: 1.45; }}
  label {{ display: block; margin: 14px 0 6px; font-size: 0.9rem; font-weight: 600; }}
  input, select {{
    width: 100%;
    padding: 11px 12px;
    border-radius: 8px;
    border: 1px solid var(--border);
    background: #0d1014;
    color: var(--fg);
    font-size: 1rem;
  }}
  button {{
    width: 100%;
    margin-top: 20px;
    padding: 12px;
    border: 0;
    border-radius: 8px;
    background: var(--accent);
    color: #fff;
    font-size: 1rem;
    font-weight: 600;
    cursor: pointer;
  }}
  button:hover {{ background: var(--accent-hover); }}
  .hidden {{ display: none; }}
  .alert {{
    padding: 12px;
    border-radius: 8px;
    margin-bottom: 14px;
    font-size: 0.92rem;
  }}
  .alert.error {{ background: var(--err-bg); color: var(--err-fg); }}
  .alert.ok {{ background: var(--ok-bg); color: var(--ok-fg); }}
</style>
</head>
<body>
<main>
  <h1>RGDS OpenCode Setup</h1>
  <p>Enter your provider settings and the 6-character pairing code shown on the device. Existing keys are never displayed.</p>
  {error_banner}
  <form method="post" action="/setup" autocomplete="off">
    <label for="provider_id">Provider</label>
    <select id="provider_id" name="provider_id" required>
      {options_html}
    </select>

    <label for="model_id">Model</label>
    <input id="model_id" name="model_id" type="text" required placeholder="claude-sonnet-4-5">

    <div id="base_url_group" class="hidden">
      <label for="base_url">Base URL</label>
      <input id="base_url" name="base_url" type="url" placeholder="https://api.example.com/v1">
    </div>

    <label for="api_key">API Key</label>
    <input id="api_key" name="api_key" type="password" required autocomplete="off" placeholder="Paste API key">

    <label for="token">Pairing Code</label>
    <input id="token" name="token" type="text" required autocomplete="off" autocapitalize="characters" maxlength="16" placeholder="6-character code">

    <button type="submit">Save and Restart OpenCode</button>
  </form>
</main>
<script>
(function() {{
  var presets = {presets_json};
  var providerEl = document.getElementById("provider_id");
  var modelEl = document.getElementById("model_id");
  var baseUrlGroup = document.getElementById("base_url_group");
  var baseUrlEl = document.getElementById("base_url");

  function applyPreset() {{
    var p = presets[providerEl.value];
    if (!p) return;
    modelEl.value = p.default_model;
    baseUrlEl.value = p.default_base_url;
    if (p.needs_base_url) {{
      baseUrlGroup.classList.remove("hidden");
      baseUrlEl.required = (providerEl.value === "custom");
    }} else {{
      baseUrlGroup.classList.add("hidden");
      baseUrlEl.required = false;
    }}
  }}

  providerEl.addEventListener("change", applyPreset);
  applyPreset();
}})();
</script>
</body>
</html>
"""


def render_success_page(provider_id: str, model_id: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RGDS OpenCode Ready</title>
<style>
  body {{
    margin: 0;
    padding: 20px 14px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: #111317;
    color: #eef1f6;
  }}
  main {{
    max-width: 440px;
    margin: 0 auto;
    background: #1a1e25;
    border: 1px solid #2e3542;
    border-radius: 12px;
    padding: 20px;
  }}
  h1 {{ margin: 0 0 10px; font-size: 1.35rem; color: #bbf7d0; }}
  p {{ margin: 0; color: #cbd5e1; line-height: 1.5; }}
  code {{ background: #0d1014; padding: 2px 6px; border-radius: 4px; }}
</style>
</head>
<body>
<main>
  <h1>OpenCode Configured</h1>
  <p>Saved model <code>{html.escape(provider_id)}/{html.escape(model_id)}</code> and restarted OpenCode. This setup server is closing now.</p>
</main>
</body>
</html>
"""


@dataclass(frozen=True)
class ServerConfig:
    token: str
    data_root: Path
    service_cmd: Path
    server_url: str
    password_file: Path
    skip_service: bool


class SetupHTTPServer(HTTPServer):
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], config: ServerConfig) -> None:
        self.setup_config = config
        super().__init__(server_address, SetupRequestHandler)


class SetupRequestHandler(BaseHTTPRequestHandler):
    server: SetupHTTPServer
    timeout = 15

    def log_message(self, format: str, *args: Any) -> None:
        cmd = getattr(self, "command", None) or "-"
        raw_path = getattr(self, "path", None) or ""
        path = urllib.parse.urlparse(raw_path).path or "-"
        sys.stderr.write(f"[opencode-setup-web] {cmd} {path}\n")

    def _wants_json(self) -> bool:
        content_type = self.headers.get("Content-Type", "")
        accept = self.headers.get("Accept", "")
        return "application/json" in content_type or "application/json" in accept

    def _send_html(self, status: HTTPStatus, body: str) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)
        self.wfile.flush()

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)
        self.wfile.flush()

    def _send_error_response(self, status: HTTPStatus, message: str, as_json: bool) -> None:
        if as_json:
            self._send_json(status, {"ok": False, "error": message})
        else:
            self._send_html(status, render_setup_page(error=message))

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/":
            self._send_html(HTTPStatus.NOT_FOUND, render_setup_page(error="Not found."))
            return
        self._send_html(HTTPStatus.OK, render_setup_page())

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        as_json = self._wants_json()
        if parsed.path != "/setup":
            self._send_error_response(HTTPStatus.NOT_FOUND, "Not found.", as_json)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_error_response(HTTPStatus.BAD_REQUEST, "Invalid Content-Length.", as_json)
            return

        if length < 0 or length > MAX_BODY_BYTES:
            self._send_error_response(HTTPStatus.BAD_REQUEST, "Request body too large.", as_json)
            return

        raw_body = self.rfile.read(length).decode("utf-8", errors="replace")
        content_type = self.headers.get("Content-Type", "")
        form: dict[str, str]
        if "application/json" in content_type:
            try:
                decoded = json.loads(raw_body)
            except json.JSONDecodeError:
                self._send_error_response(HTTPStatus.BAD_REQUEST, "Invalid JSON payload.", True)
                return
            if not isinstance(decoded, dict):
                self._send_error_response(HTTPStatus.BAD_REQUEST, "JSON payload must be an object.", True)
                return
            form = {str(k): "" if v is None else str(v) for k, v in decoded.items()}
        else:
            qs = urllib.parse.parse_qs(raw_body, keep_blank_values=True)
            form = {k: vals[0] if vals else "" for k, vals in qs.items()}

        cfg = self.server.setup_config
        try:
            inp = parse_and_validate_form(form, cfg.token)
        except AuthError as exc:
            self._send_error_response(HTTPStatus.FORBIDDEN, str(exc), as_json)
            return
        except ValidationError as exc:
            self._send_error_response(HTTPStatus.BAD_REQUEST, str(exc), as_json)
            return

        try:
            self._apply_setup(inp, cfg)
        except (RuntimeError, OSError) as exc:
            server_pw = ""
            try:
                server_pw = read_server_password(cfg.password_file)
            except (RuntimeError, OSError):
                pass
            basic_token = ""
            if server_pw:
                basic_token = base64.b64encode(f"opencode:{server_pw}".encode()).decode()
            submitted_token = str(form.get("token", "")).strip()
            safe_msg = redact_secrets(
                str(exc),
                inp.api_key,
                server_pw,
                basic_token,
                cfg.token,
                submitted_token,
            )
            self._send_error_response(HTTPStatus.INTERNAL_SERVER_ERROR, safe_msg, as_json)
            return

        if as_json:
            self._send_json(
                HTTPStatus.OK,
                {"ok": True, "model": f"{inp.provider_id}/{inp.model_id}"},
            )
        else:
            self._send_html(HTTPStatus.OK, render_success_page(inp.provider_id, inp.model_id))

        threading.Thread(target=self.server.shutdown, daemon=True).start()

    @staticmethod
    def _apply_setup(inp: SetupInput, cfg: ServerConfig) -> None:
        config_path = cfg.data_root / "config" / "opencode" / "opencode.json"

        cfg.data_root.mkdir(parents=True, exist_ok=True)
        os.chmod(cfg.data_root, 0o700)
        config_path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(config_path.parent, 0o700)

        prior_existed = config_path.is_file()
        prior_bytes = config_path.read_bytes() if prior_existed else None

        existing_cfg = load_existing_json(config_path)
        new_cfg = build_opencode_config(inp, existing_cfg)
        atomic_write_json(config_path, new_cfg, mode=0o600)

        if cfg.skip_service:
            return

        service_env = os.environ.copy()
        service_env["OPENCODE_DATA_ROOT"] = str(cfg.data_root)
        service_env["OPENCODE_PASSWORD_FILE"] = str(cfg.password_file)

        def rollback_config() -> None:
            try:
                if prior_existed:
                    atomic_write_bytes(config_path, prior_bytes or b"", mode=0o600)
                elif config_path.exists():
                    config_path.unlink()
            except OSError:
                pass
            try:
                subprocess.run(
                    [str(cfg.service_cmd), "restart"],
                    env=service_env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError):
                pass

        try:
            try:
                result = subprocess.run(
                    [str(cfg.service_cmd), "restart"],
                    env=service_env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise RuntimeError(f"Failed to restart opencode service: {exc}") from exc

            if result.returncode != 0:
                detail = (result.stderr or result.stdout or "").strip()
                raise RuntimeError(
                    f"opencode service restart failed (exit {result.returncode}): {detail}"
                )

            server_password = read_server_password(cfg.password_file)
            auth_header = basic_auth_header(server_password)
            base_url = cfg.server_url.rstrip("/")

            info_req = urllib.request.Request(
                f"{base_url}/api/info",
                headers={"Authorization": auth_header},
                method="GET",
            )
            try:
                with urllib.request.urlopen(info_req, timeout=5) as resp:
                    if resp.status != 200:
                        raise RuntimeError(f"Server info check returned HTTP {resp.status}.")
            except (OSError, urllib.error.URLError) as exc:
                raise RuntimeError(f"OpenCode server check failed: {exc}") from exc

            cred_body = json.dumps(build_credential_payload(inp)).encode("utf-8")
            cred_req = urllib.request.Request(
                f"{base_url}/api/credential",
                data=cred_body,
                headers={
                    "Authorization": auth_header,
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(cred_req, timeout=5) as resp:
                    if resp.status not in (200, 201):
                        raise RuntimeError(f"Credential API returned HTTP {resp.status}.")
            except urllib.error.HTTPError as exc:
                with exc:
                    detail = exc.read().decode("utf-8", errors="replace").strip()
                raise RuntimeError(
                    f"OpenCode credential store failed (HTTP {exc.code}): {detail}"
                ) from exc
            except (OSError, urllib.error.URLError) as exc:
                raise RuntimeError(f"OpenCode credential store failed: {exc}") from exc
        except Exception:
            rollback_config()
            raise


def build_arg_parser() -> argparse.ArgumentParser:
    default_service = Path(__file__).resolve().parent / "opencode-service.sh"
    parser = argparse.ArgumentParser(description="RGDS OpenCode web setup wizard")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--data-root", default="/userdata/opencode")
    parser.add_argument("--service-cmd", default=str(default_service))
    parser.add_argument("--server-url", default="http://127.0.0.1:4096")
    parser.add_argument("--password-file", default=None)
    parser.add_argument("--status-file", default="/tmp/opencode-setup.json")
    parser.add_argument("--token", default=None)
    parser.add_argument("--skip-service", action="store_true")
    return parser


def run_server(args: argparse.Namespace) -> int:
    if args.token is not None and SETUP_TOKEN_RE.fullmatch(args.token.strip()) is None:
        print(
            "error: --token must be a 6-character pairing code matching ^[A-Za-z0-9]{6}$.",
            file=sys.stderr,
        )
        return 2
    token = args.token.strip().upper() if args.token else generate_token()
    data_root = Path(args.data_root)
    password_file = Path(args.password_file) if args.password_file else (data_root / "server.password")
    config = ServerConfig(
        token=token,
        data_root=data_root,
        service_cmd=Path(args.service_cmd),
        server_url=args.server_url,
        password_file=password_file,
        skip_service=bool(args.skip_service),
    )
    status_path = Path(args.status_file)
    server = SetupHTTPServer((args.host, args.port), config)

    actual_port = server.server_address[1]
    lan_host = detect_lan_ip() if args.host in ("0.0.0.0", "") else args.host
    url = f"http://{lan_host}:{actual_port}/"
    status_payload = {
        "ip": lan_host,
        "port": actual_port,
        "url": url,
        "token": token,
    }
    atomic_write_json(status_path, status_payload, mode=0o600)

    def _handle_signal(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, _handle_signal)
        signal.signal(signal.SIGINT, _handle_signal)

    print(f"OpenCode setup listening on {url} (token: {token})", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            status_path.unlink(missing_ok=True)
        except OSError:
            pass
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    return run_server(args)


if __name__ == "__main__":
    raise SystemExit(main())
