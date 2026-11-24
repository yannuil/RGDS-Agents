#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OPENCODE_BIN="${OPENCODE_BIN:-$SCRIPT_DIR/bin/opencode}"
OPENCODE_DATA_ROOT="${OPENCODE_DATA_ROOT:-/userdata/opencode}"
OPENCODE_WORKDIR="${OPENCODE_WORKDIR:-/mnt/mmc/Roms/APPS/RGDS-Agents}"
OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCODE_PID_FILE="${OPENCODE_PID_FILE:-/tmp/opencode-serve.pid}"
OPENCODE_LOG_FILE="${OPENCODE_LOG_FILE:-/tmp/opencode-serve.log}"
OPENCODE_PASSWORD_FILE="${OPENCODE_PASSWORD_FILE:-$OPENCODE_DATA_ROOT/server.password}"
OPENCODE_LOCK_DIR="${OPENCODE_LOCK_DIR:-/tmp/opencode-service.lock}"
_lock_held=0

export HOME="${HOME:-/root}"
export XDG_CONFIG_HOME="$OPENCODE_DATA_ROOT/config"
export XDG_DATA_HOME="$OPENCODE_DATA_ROOT/share"
export XDG_STATE_HOME="$OPENCODE_DATA_ROOT/state"
export XDG_CACHE_HOME="$OPENCODE_DATA_ROOT/cache"

HEALTH_URL="http://${OPENCODE_HOST}:${OPENCODE_PORT}/api/info"

read_password() {
  [ -f "$OPENCODE_PASSWORD_FILE" ] || return 1
  pw="$(head -n 1 "$OPENCODE_PASSWORD_FILE" 2>/dev/null | tr -d '\r\n')"
  [ -n "$pw" ] || return 1
  printf '%s\n' "$pw"
}

ensure_password() {
  if existing_pw="$(read_password)"; then
    chmod 600 "$OPENCODE_PASSWORD_FILE" 2>/dev/null || true
    printf '%s\n' "$existing_pw"
    return 0
  fi
  pw_dir="$(dirname "$OPENCODE_PASSWORD_FILE")"
  mkdir -p "$pw_dir"
  chmod 700 "$pw_dir" 2>/dev/null || true
  if command -v python3 >/dev/null 2>&1; then
    pw="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  else
    pw="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
  fi
  pw_tmp="${OPENCODE_PASSWORD_FILE}.tmp.$$"
  (
    umask 077
    printf '%s\n' "$pw" > "$pw_tmp"
  )
  chmod 600 "$pw_tmp"
  mv "$pw_tmp" "$OPENCODE_PASSWORD_FILE"
  printf '%s\n' "$pw"
}

is_pid_alive() {
  pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/stat" ]; then
    case "$(cat "/proc/$pid/stat" 2>/dev/null || true)" in
      *") Z "*|*") X "*) return 1 ;;
    esac
  fi
  return 0
}

is_opencode_pid() {
  pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  is_pid_alive "$pid" || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmdline" in
    *opencode*serve*) return 0 ;;
    *) return 1 ;;
  esac
}

running_pid() {
  [ -f "$OPENCODE_PID_FILE" ] || return 1
  pid="$(head -n 1 "$OPENCODE_PID_FILE" 2>/dev/null || true)"
  if is_opencode_pid "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 1
}

is_healthy() {
  pw="$(read_password || true)"
  [ -n "$pw" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    OPENCODE_CHECK_PASSWORD="$pw" python3 -c '
import base64, os, sys, urllib.request
pw = os.environ["OPENCODE_CHECK_PASSWORD"]
token = base64.b64encode(("opencode:" + pw).encode("utf-8")).decode("ascii")
req = urllib.request.Request(sys.argv[1], headers={"Authorization": "Basic " + token})
with urllib.request.urlopen(req, timeout=2) as resp:
    sys.exit(0 if resp.status == 200 else 1)
' "$HEALTH_URL" >/dev/null 2>&1
  elif command -v curl >/dev/null 2>&1; then
    printf 'user = "opencode:%s"\n' "$pw" | curl -sf --max-time 2 -K - "$HEALTH_URL" >/dev/null 2>&1
  else
    return 1
  fi
}

# BusyBox ash runs EXIT traps in subshells. Drop the trap before any $(...)
# and only remove the directory from the process that acquired it.
release_lifecycle_lock() {
  trap - EXIT INT TERM
  if [ "$_lock_held" != 1 ]; then
    return 0
  fi
  owner_pid=$(exec sh -c 'echo "$PPID"' 2>/dev/null || true)
  if [ "$owner_pid" != "$$" ]; then
    return 0
  fi
  rm -rf "$OPENCODE_LOCK_DIR"
  _lock_held=0
}

lock_owner_alive() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null
}

read_lock_owner() {
  if [ -f "$OPENCODE_LOCK_DIR/pid" ]; then
    head -n 1 "$OPENCODE_LOCK_DIR/pid" 2>/dev/null | tr -d '[:space:]' || true
  fi
  return 0
}

acquire_lifecycle_lock() {
  trap 'release_lifecycle_lock' EXIT
  trap 'release_lifecycle_lock; exit 1' INT TERM
  while :; do
    if mkdir -m 700 "$OPENCODE_LOCK_DIR" 2>/dev/null; then
      _lock_held=1
      printf '%s\n' "$$" > "$OPENCODE_LOCK_DIR/pid"
      return 0
    fi
    owner="$(read_lock_owner)"
    if lock_owner_alive "$owner"; then
      sleep 0.2
      continue
    fi
    sleep 0.2
    owner="$(read_lock_owner)"
    if lock_owner_alive "$owner"; then
      sleep 0.2
      continue
    fi
    rm -rf "$OPENCODE_LOCK_DIR" || true
  done
}

_stop() {
  pid="$(running_pid || true)"
  if [ -z "$pid" ]; then
    rm -f "$OPENCODE_PID_FILE"
    echo "opencode stopped"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 25 ]; do
    if ! is_opencode_pid "$pid"; then
      rm -f "$OPENCODE_PID_FILE"
      echo "opencode stopped (pid $pid)"
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "!! opencode (pid $pid) did not exit after 5s" >&2
  return 1
}

_start() {
  existing="$(running_pid || true)"
  if [ -n "$existing" ] && is_healthy; then
    echo "opencode already running (pid $existing)"
    return 0
  fi
  if [ -n "$existing" ]; then
    _stop
  else
    rm -f "$OPENCODE_PID_FILE"
  fi

  if [ ! -x "$OPENCODE_BIN" ]; then
    echo "!! opencode binary not executable: $OPENCODE_BIN" >&2
    return 1
  fi
  if [ ! -d "$OPENCODE_WORKDIR" ]; then
    echo "!! workdir not found: $OPENCODE_WORKDIR" >&2
    return 1
  fi

  mkdir -p \
    "$OPENCODE_DATA_ROOT" \
    "$XDG_CONFIG_HOME/opencode" \
    "$XDG_DATA_HOME/opencode" \
    "$XDG_STATE_HOME/opencode" \
    "$XDG_CACHE_HOME/opencode"
  chmod 700 "$OPENCODE_DATA_ROOT" "$XDG_CONFIG_HOME/opencode" "$XDG_DATA_HOME/opencode"

  pw="$(ensure_password)"

  if [ -f "$SCRIPT_DIR/AGENTS.md" ] && [ ! -f "$XDG_CONFIG_HOME/opencode/AGENTS.md" ]; then
    cp "$SCRIPT_DIR/AGENTS.md" "$XDG_CONFIG_HOME/opencode/AGENTS.md"
  fi

  (
    trap '' HUP
    cd "$OPENCODE_WORKDIR"
    export OPENCODE_PASSWORD="$pw"
    exec "$OPENCODE_BIN" serve --hostname "$OPENCODE_HOST" --port "$OPENCODE_PORT"
  ) >> "$OPENCODE_LOG_FILE" 2>&1 </dev/null &
  pid=$!

  pid_tmp="${OPENCODE_PID_FILE}.tmp.$$"
  printf '%s\n' "$pid" > "$pid_tmp"
  mv "$pid_tmp" "$OPENCODE_PID_FILE"

  i=0
  while [ "$i" -lt 30 ]; do
    if ! is_pid_alive "$pid"; then
      rm -f "$OPENCODE_PID_FILE"
      echo "!! opencode exited before becoming healthy (log: $OPENCODE_LOG_FILE)" >&2
      return 1
    fi
    if is_healthy; then
      echo "opencode started (pid $pid)"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done

  if is_opencode_pid "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  rm -f "$OPENCODE_PID_FILE"
  echo "!! opencode did not become healthy within 15s (log: $OPENCODE_LOG_FILE)" >&2
  return 1
}

status_service() {
  pid="$(running_pid || true)"
  if [ -z "$pid" ]; then
    echo "stopped (pid: none, health: down)"
    return 1
  fi
  if is_healthy; then
    echo "running (pid: $pid, health: ok)"
    return 0
  fi
  echo "running (pid: $pid, health: unhealthy)"
  return 1
}

case "${1:-}" in
  start)
    acquire_lifecycle_lock
    _start
    ;;
  stop)
    acquire_lifecycle_lock
    _stop
    ;;
  restart)
    acquire_lifecycle_lock
    _stop
    _start
    ;;
  status)
    status_service
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
