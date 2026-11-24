#!/bin/sh
set -eu

TARGET="${1:-root@rgds.local}"
IDENTITY="${RGDS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
REMOTE_PORT="${RGDS_OPENCODE_PORT:-4096}"
REMOTE_DATA_ROOT="${RGDS_OPENCODE_DATA_ROOT:-/userdata/opencode}"
LOCAL_PORT="${RGDS_LOCAL_PORT:-}"

if ! command -v opencode >/dev/null 2>&1; then
  echo "!! opencode not found in PATH. Install OpenCode v2 from https://opencode.ai/v2/docs" >&2
  exit 1
fi

if [ -z "$LOCAL_PORT" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "!! set RGDS_LOCAL_PORT or install python3 to pick a free local port" >&2
    exit 1
  fi
  LOCAL_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
fi

CTRL_DIR="$(mktemp -d /tmp/rgds-opencode-ssh.XXXXXX)"
chmod 700 "$CTRL_DIR"
CTRL_SOCK="$CTRL_DIR/ctrl"

cleanup() {
  if [ -S "$CTRL_SOCK" ]; then
    ssh -S "$CTRL_SOCK" -O exit "$TARGET" >/dev/null 2>&1 || true
  fi
  rm -rf "$CTRL_DIR"
}
trap cleanup EXIT INT TERM

ssh -M -S "$CTRL_SOCK" -f -N \
  -o ExitOnForwardFailure=yes \
  -o IdentitiesOnly=yes \
  -o IdentityFile="$IDENTITY" \
  -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
  "$TARGET"

PASSWORD="$(ssh -S "$CTRL_SOCK" "$TARGET" "head -n 1 '${REMOTE_DATA_ROOT}/server.password' 2>/dev/null | tr -d '\r\n'" || true)"
if [ -z "$PASSWORD" ]; then
  echo "!! missing ${REMOTE_DATA_ROOT}/server.password on ${TARGET}" >&2
  echo "!! start opencode on the RGDS first: ssh -o IdentitiesOnly=yes -o IdentityFile=\"$IDENTITY\" \"$TARGET\" '/mnt/mmc/Roms/APPS/RGDS-Agents/opencode/opencode-service.sh start'" >&2
  exit 1
fi

if ! printf 'user = "opencode:%s"\n' "$PASSWORD" | curl -sf --max-time 3 -K - "http://127.0.0.1:${LOCAL_PORT}/api/info" >/dev/null 2>&1; then
  echo "!! opencode serve is not responding on ${TARGET}:${REMOTE_PORT}" >&2
  echo "!! start it on the RGDS: ssh -o IdentitiesOnly=yes -o IdentityFile=\"$IDENTITY\" \"$TARGET\" '/mnt/mmc/Roms/APPS/RGDS-Agents/opencode/opencode-service.sh start'" >&2
  exit 1
fi

OPENCODE_PASSWORD="$PASSWORD" opencode --server "http://127.0.0.1:${LOCAL_PORT}"
