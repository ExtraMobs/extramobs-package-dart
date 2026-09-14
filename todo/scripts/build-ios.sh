#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/build-ios.sh /abs/path/to/third_party/freetds-1.5.4 /abs/path/to/outdir
#
# Produces:
#   $OUT_DIR/FreeTDS.xcframework (static)
#
# Notes:
# - We build static libs for iOS (best practice) and wrap into an XCFramework.
# - We compile for device (arm64) and simulator (arm64 + x86_64) and lipo where needed.

SRC_DIR="$1"
OUT_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build function using Xcode SDK + clang for iOS
build_one() {
  local SDK="$1"         # iphoneos or iphonesimulator
  local ARCHS="$2"       # e.g. "arm64" or "arm64 x86_64"
  local PREFIX="$3"      # install prefix
  local HOST              # config.guess host triple approximation
  local TLS_DIR="$OUT_DIR/openssl-$SDK-$ARCHS"
  local TLS_TARGET='ios64-xcrun'
  if [[ "$SDK" == iphonesimulator ]]; then TLS_TARGET="iossimulator-$ARCHS-xcrun"; fi
  bash "$SCRIPT_DIR/build-openssl.sh" "$TLS_TARGET" "$TLS_DIR" -arch "$ARCHS"
  local TLS_PREFIX="$TLS_DIR/prefix"

  case "$SDK" in
    iphoneos) HOST="arm-apple-darwin" ;;
    iphonesimulator) HOST="x86_64-apple-darwin" ;; # configure just needs *something* non-native
  esac

  rm -rf "$PREFIX" && mkdir -p "$PREFIX"
  pushd "$SRC_DIR" >/dev/null

  [ -f Makefile ] && make distclean || true
  rm -rf build-ios && mkdir build-ios && cd build-ios

  # FLAGS
  SDK_PATH="$(xcrun --sdk $SDK --show-sdk-path)"
  local TARGET="$ARCHS-apple-ios13.0"
  if [[ "$SDK" == iphonesimulator ]]; then TARGET="$TARGET-simulator"; fi
  CFLAGS="-isysroot $SDK_PATH -target $TARGET"
  LDFLAGS="-isysroot $SDK_PATH -target $TARGET"

  # Select the first arch for configure (we'll fatten later if needed)
  CFG_ARCH="$(echo "$ARCHS" | awk '{print $1}')"

  # Ensure autotools files are (re)generated to avoid versioned aclocal invocations on CI
  # Make gettext m4 macros discoverable when installed via Homebrew
  # Prepare autotools only if configure.ac is present
  if [ -f ../configure.ac ]; then
    mkdir -p ../m4
    if command -v brew >/dev/null 2>&1; then
      GETTEXT_PREFIX="$(brew --prefix gettext 2>/dev/null || true)"
      if [ -n "$GETTEXT_PREFIX" ]; then
        cp -f "$GETTEXT_PREFIX/share/aclocal/iconv.m4" ../m4/iconv.m4 2>/dev/null || true
        export ACLOCAL_PATH="$GETTEXT_PREFIX/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
      fi
    fi
    (cd .. && autoreconf -fi)
  fi
  chmod +x ../configure || true

  env \
    CC="$(xcrun -f clang)" \
    CXX="$(xcrun -f clang++)" \
    CFLAGS="$CFLAGS -arch $CFG_ARCH" \
    LDFLAGS="$LDFLAGS -arch $CFG_ARCH" \
    ../configure \
      --host="$HOST" \
      --prefix="$PREFIX" \
      --disable-shared \
      --enable-static \
      --disable-libiconv \
      --with-openssl="$TLS_PREFIX" \
  --enable-msdblib \
      --disable-apps \
      --disable-server

  make -j"$(sysctl -n hw.ncpu)"
  make install
  grep -q '^#define HAVE_OPENSSL 1' include/config.h
  xcrun libtool -static -o "$PREFIX/lib/libsybdb-tls.a" \
    "$PREFIX/lib/libsybdb.a" "$TLS_PREFIX/lib/libssl.a" "$TLS_PREFIX/lib/libcrypto.a"
  mv "$PREFIX/lib/libsybdb-tls.a" "$PREFIX/lib/libsybdb.a"

  popd >/dev/null
}

mkdir -p "$OUT_DIR"
DEVICE_PREFIX="$OUT_DIR/ios-device-prefix"
SIM_PREFIX_A="$OUT_DIR/ios-sim-arm64-prefix"
SIM_PREFIX_X="$OUT_DIR/ios-sim-x86_64-prefix"

# Build device (arm64)
build_one iphoneos "arm64" "$DEVICE_PREFIX"

# Build simulator arm64 & x86_64 separately, then lipo-merge
build_one iphonesimulator "arm64" "$SIM_PREFIX_A"
build_one iphonesimulator "x86_64" "$SIM_PREFIX_X"

# Merge simulator static libs
SIM_LIB_DIR="$OUT_DIR/ios-sim-universal/lib"
mkdir -p "$SIM_LIB_DIR"
for LIB in "$SIM_PREFIX_A/lib/"*.a; do
  NAME="$(basename "$LIB")"
  lipo -create -output "$SIM_LIB_DIR/$NAME" "$LIB" "$SIM_PREFIX_X/lib/$NAME"
done

# Create DB-Lib XCFramework (libsybdb.a)
IOS_DEVICE_DBLIB="$(ls "$DEVICE_PREFIX/lib/libsybdb.a")"
IOS_SIM_DBLIB="$(ls "$SIM_LIB_DIR/libsybdb.a")"

rm -rf "$OUT_DIR/FreeTDS-DB.xcframework"
xcodebuild -create-xcframework \
  -library "$IOS_DEVICE_DBLIB" -headers "$DEVICE_PREFIX/include" \
  -library "$IOS_SIM_DBLIB"    -headers "$SIM_PREFIX_A/include" \
  -output "$OUT_DIR/FreeTDS-DB.xcframework"

# Create CT-Lib XCFramework (libct.a)
IOS_DEVICE_CTLIB="$(ls "$DEVICE_PREFIX/lib/libct.a")"
IOS_SIM_CTLIB="$(ls "$SIM_LIB_DIR/libct.a")"

rm -rf "$OUT_DIR/FreeTDS-CT.xcframework"
xcodebuild -create-xcframework \
  -library "$IOS_DEVICE_CTLIB" -headers "$DEVICE_PREFIX/include" \
  -library "$IOS_SIM_CTLIB"    -headers "$SIM_PREFIX_A/include" \
  -output "$OUT_DIR/FreeTDS-CT.xcframework"

echo "Built iOS XCFrameworks at: $OUT_DIR/FreeTDS-DB.xcframework and $OUT_DIR/FreeTDS-CT.xcframework"
