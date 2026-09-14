#!/usr/bin/env bash
set -euo pipefail
# TARGET: linux-x86_64, darwin64-arm64-cc, android-arm64, ios64-xcrun, etc.
TARGET="$1"
OUT_DIR="$2"
shift 2
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
SOURCE="$(python3 "$(dirname "$0")/fetch-openssl.py" "$OUT_DIR/source")"
if [[ "$TARGET" == android-* ]]; then
  : "${ANDROID_NDK:?Set ANDROID_NDK}"
  export ANDROID_NDK_ROOT="$ANDROID_NDK"
  export PATH="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
fi
cd "$SOURCE"
perl Configure "$TARGET" no-shared no-tests -fPIC --libdir=lib --prefix="$OUT_DIR/prefix" "$@"
make -j"$(getconf _NPROCESSORS_ONLN)"
make install_sw
