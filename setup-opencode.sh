#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CACHE="$ROOT/.cache"
OPENCODE_VERSION="v2.4.0"
OPENCODE_REPO="anomalyco/opencode"
OPENCODE_ASSET="opencode-linux-arm64.tar.gz"
OPENCODE_URL="https://github.com/${OPENCODE_REPO}/releases/download/${OPENCODE_VERSION}/${OPENCODE_ASSET}"
OPENCODE_SHA256="fed468566215fd38b26abab99018240c0d30772d3f45aee25621664ceff7e360"

ARCHIVE="$CACHE/${OPENCODE_VERSION}-${OPENCODE_ASSET}"
STAMP="$CACHE/opencode.sha256"
TARGET="opencode/bin/opencode"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "!! neither sha256sum nor shasum found" >&2
    exit 1
  fi
}

fetch_archive() {
  dest="$1"
  if [ -s "$dest" ] && [ "$(sha256_of "$dest")" = "$OPENCODE_SHA256" ]; then
    echo ">> already have $(basename "$dest")"
    return 0
  fi
  rm -f "$dest.partial"
  mkdir -p "$(dirname "$dest")"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo ">> download $(basename "$dest") via gh"
    gh release download "$OPENCODE_VERSION" \
      --repo "$OPENCODE_REPO" \
      --pattern "$OPENCODE_ASSET" \
      --output "$dest.partial"
  else
    echo ">> download $(basename "$dest") via curl"
    curl -fL --retry 3 --retry-delay 2 -o "$dest.partial" "$OPENCODE_URL"
  fi
  mv "$dest.partial" "$dest"
}

mkdir -p "$CACHE" opencode/bin

if [ -x "$TARGET" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$OPENCODE_SHA256" ]; then
  echo ">> $TARGET already matches $OPENCODE_VERSION"
  exit 0
fi

fetch_archive "$ARCHIVE"

got="$(sha256_of "$ARCHIVE")"
if [ "$got" != "$OPENCODE_SHA256" ]; then
  echo "!! $(basename "$ARCHIVE") sha256 $got, expected $OPENCODE_SHA256" >&2
  rm -f "$ARCHIVE"
  exit 1
fi

EXTRACT_DIR="$CACHE/opencode-extract-$$"
trap 'rm -rf "$EXTRACT_DIR"' EXIT INT TERM
mkdir -p "$EXTRACT_DIR"

echo ">> extract $OPENCODE_ASSET"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

BIN_SRC=""
if [ -f "$EXTRACT_DIR/opencode" ]; then
  BIN_SRC="$EXTRACT_DIR/opencode"
else
  BIN_SRC="$(find "$EXTRACT_DIR" -type f -name opencode | head -n 1)"
fi

if [ -z "$BIN_SRC" ] || [ ! -f "$BIN_SRC" ]; then
  echo "!! opencode binary not found inside $OPENCODE_ASSET" >&2
  exit 1
fi

cp "$BIN_SRC" "${TARGET}.new"
chmod +x "${TARGET}.new"
mv "${TARGET}.new" "$TARGET"

printf '%s\n' "$OPENCODE_SHA256" > "${STAMP}.tmp"
mv "${STAMP}.tmp" "$STAMP"

echo ">> installed $TARGET ($OPENCODE_VERSION)"
echo "Next: ./deploy.sh rgds"
