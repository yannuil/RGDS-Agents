#!/bin/sh
# Download the SenseVoice model and the sherpa-onnx libs sv-helper links, then
# build stt/sv-helper for aarch64. Run this on the dev machine from the repo root.
# On the device (aarch64) the same script uses the native gcc.
#
# The helper already in this tree was linked against the v2.0.1 shared build,
# not the static tools archive:
#   gcc -O2 -mcpu=cortex-a55 sv-helper.c -lsherpa-onnx-c-api -Wl,-rpath,'$ORIGIN/lib'
# Runtime needs stt/lib/libsherpa-onnx-c-api.so and stt/lib/libonnxruntime.so.

set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CACHE="$ROOT/.cache"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
MODEL_MD5="0e8e550411d3589be9f0af06f1c8fec3"
SHERPA_NAME="sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/${SHERPA_NAME}.tar.bz2"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/sherpa-onnx/c-api/c-api.h"

# The 2025-09-09 archive is a Cantonese fine-tune. Do not substitute it.
case "$MODEL_URL" in
  *2025-09-09*) echo "!! refusing the 2025-09-09 Cantonese fine-tune" >&2; exit 1 ;;
esac

fetch() {
  url="$1"
  dest="$2"
  if [ -s "$dest" ]; then
    echo ">> already have $(basename "$dest")"
    return 0
  fi
  echo ">> download $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 3 --retry-delay 2 -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
}

md5_of() {
  md5sum "$1" | awk '{print $1}'
}

mkdir -p "$CACHE" stt/lib

if [ -f stt/model.int8.onnx ] && [ "$(md5_of stt/model.int8.onnx)" = "$MODEL_MD5" ]; then
  echo ">> model.int8.onnx already matches $MODEL_MD5"
else
  fetch "$MODEL_URL" "$CACHE/${MODEL_NAME}.tar.bz2"
  echo ">> extract model.int8.onnx"
  tar -xjf "$CACHE/${MODEL_NAME}.tar.bz2" -C "$CACHE" "$MODEL_NAME/model.int8.onnx"
  got="$(md5_of "$CACHE/$MODEL_NAME/model.int8.onnx")"
  if [ "$got" != "$MODEL_MD5" ]; then
    echo "!! model.int8.onnx md5 $got, expected $MODEL_MD5" >&2
    exit 1
  fi
  cp "$CACHE/$MODEL_NAME/model.int8.onnx" stt/model.int8.onnx
  if [ ! -f stt/tokens.txt ]; then
    tar -xjf "$CACHE/${MODEL_NAME}.tar.bz2" -C "$CACHE" "$MODEL_NAME/tokens.txt"
    cp "$CACHE/$MODEL_NAME/tokens.txt" stt/tokens.txt
  fi
fi

fetch "$SHERPA_URL" "$CACHE/${SHERPA_NAME}.tar.bz2"
echo ">> extract sherpa-onnx shared libs"
tar -xjf "$CACHE/${SHERPA_NAME}.tar.bz2" -C "$CACHE" \
  "$SHERPA_NAME/lib/libsherpa-onnx-c-api.so" \
  "$SHERPA_NAME/lib/libonnxruntime.so"
cp "$CACHE/$SHERPA_NAME/lib/libsherpa-onnx-c-api.so" \
   "$CACHE/$SHERPA_NAME/lib/libonnxruntime.so" \
   stt/lib/

mkdir -p "$CACHE/include/sherpa-onnx/c-api"
fetch "$HEADER_URL" "$CACHE/include/sherpa-onnx/c-api/c-api.h"

# Ignore a host CC from the environment. This binary has to be aarch64.
if [ "$(uname -m)" = "aarch64" ]; then
  COMPILER=gcc
else
  COMPILER=aarch64-linux-gnu-gcc
fi
if ! command -v "$COMPILER" >/dev/null 2>&1; then
  echo "!! $COMPILER not found. On Fedora: sudo dnf install gcc-aarch64-linux-gnu" >&2
  echo "!! On Debian/Ubuntu: sudo apt install gcc-aarch64-linux-gnu" >&2
  exit 1
fi

SYSROOT=""
if ! printf '#include <stdint.h>\nint main(void){return 0;}\n' | "$COMPILER" -x c - -c -o /dev/null >/dev/null 2>&1; then
  for d in /usr/aarch64-redhat-linux/sys-root/fc*; do
    if [ -f "$d/usr/include/stdint.h" ]; then
      SYSROOT="$d"
    fi
  done
  if [ -z "$SYSROOT" ]; then
    echo "!! $COMPILER has no aarch64 libc headers." >&2
    echo "!! Fedora: sudo dnf install sysroot-aarch64-fc*-glibc" >&2
    echo "!! Debian/Ubuntu: sudo apt install libc6-dev-arm64-cross" >&2
    exit 1
  fi
fi

echo ">> build stt/sv-helper ($COMPILER -O2 -mcpu=cortex-a55)"
set -- \
  -O2 -mcpu=cortex-a55 -fPIE -pie \
  -o stt/sv-helper.new stt/sv-helper.c \
  -I "$CACHE/include" \
  -L stt/lib -lsherpa-onnx-c-api \
  -Wl,-rpath,'$ORIGIN/lib' -Wl,--enable-new-dtags
if [ -n "$SYSROOT" ]; then
  set -- --sysroot="$SYSROOT" "$@"
fi
# Fedora's cross sysroot has glibc but not libstdc++. The .so still loads
# libstdc++.so.6 on the device, same as the original helper.
if ! "$COMPILER" "$@" >/dev/null 2>&1; then
  "$COMPILER" "$@" -Wl,--unresolved-symbols=ignore-in-shared-libs
fi
mv stt/sv-helper.new stt/sv-helper
chmod +x stt/sv-helper

echo ">> built $(file stt/sv-helper)"
echo
echo "Next: ./deploy.sh rgds"
