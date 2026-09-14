#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ANDROID_NDK=<path> ./scripts/build-android.sh /abs/path/to/third_party/freetds-1.5.4 /abs/path/to/outdir "arm64-v8a armeabi-v7a x86_64"
#
# Produces:
#   $OUT_DIR/<ABI>/libsybdb.so

SRC_DIR="$1"
OUT_DIR="$2"
ABIS="${3:-arm64-v8a}"

: "${ANDROID_NDK:?ANDROID_NDK env var must be set}"
: "${OPENSSL_ROOT_DIR:?Set OPENSSL_ROOT_DIR to the matching ABI static OpenSSL prefix}"
test -f "$OPENSSL_ROOT_DIR/lib/libssl.a"
test -f "$OPENSSL_ROOT_DIR/lib/libcrypto.a"

mkdir -p "$OUT_DIR"

for ABI in $ABIS; do
  BUILD_DIR="$OUT_DIR/build-$ABI"
  rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
  pushd "$BUILD_DIR" >/dev/null

  cmake "$SRC_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM=21 \
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR" \
    -DOPENSSL_INCLUDE_DIR="$OPENSSL_ROOT_DIR/include" \
    -DOPENSSL_SSL_LIBRARY="$OPENSSL_ROOT_DIR/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_ROOT_DIR/lib/libcrypto.a" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DWITH_OPENSSL=ON \
    -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_MSDBLIB=ON

  # Work around Android lacking system iconv: force-disable HAVE_ICONV in generated config.h
  # so FreeTDS uses its internal replacements instead of system iconv.
  CONFIG_H="$BUILD_DIR/include/config.h"
  grep -q '^#define HAVE_OPENSSL 1' "$CONFIG_H" || { echo 'TLS support was not enabled' >&2; exit 1; }
  if [ -f "$CONFIG_H" ]; then
    # Replace a strict match to avoid unintended changes
    sed -i.bak -e 's/^#define HAVE_ICONV 1$/#undef HAVE_ICONV/' "$CONFIG_H" || true
  fi

  # Build only dblib and ct targets to avoid compiling ODBC (which needs unixODBC/iODBC headers)
  cmake --build . --config Release --target sybdb ct -j

  # Find produced libs (libsybdb and its dependencies)
  mkdir -p "$OUT_DIR/$ABI"
  find . -name "lib*.so" -maxdepth 3 -print -exec cp {} "$OUT_DIR/$ABI/" \;

  popd >/dev/null
done

echo "Built Android libs into: $OUT_DIR/<ABI>"
