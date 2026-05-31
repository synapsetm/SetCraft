#!/usr/bin/env bash
# Build TagLib as a static library for macOS (arm64 + x86_64) and package
# it as an .xcframework consumable by Swift Package Manager.
#
# Output: Vendor/TagLib.xcframework  (committed to the repo)
#
# Requires: cmake, xcodebuild

set -euo pipefail

# xcodebuild requires a full Xcode install (not just CommandLineTools).
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

TAGLIB_VERSION="2.1"
UTFCPP_VERSION="4.0.6"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK_DIR="$HERE/build"
SRC_DIR="$HERE/src"
INSTALL_MACOS="$WORK_DIR/install-macos"
XCF_OUT="$REPO_ROOT/SetifyCore/Vendor/TagLib.xcframework"

mkdir -p "$WORK_DIR" "$SRC_DIR"

# --- Fetch sources ------------------------------------------------------------

TAGLIB_SRC="$SRC_DIR/taglib-$TAGLIB_VERSION"
UTFCPP_SRC="$SRC_DIR/utfcpp-$UTFCPP_VERSION"

if [ ! -d "$TAGLIB_SRC" ]; then
  echo "==> Downloading TagLib $TAGLIB_VERSION"
  curl -fsSL "https://github.com/taglib/taglib/releases/download/v$TAGLIB_VERSION/taglib-$TAGLIB_VERSION.tar.gz" \
    -o "$SRC_DIR/taglib.tar.gz"
  tar -xzf "$SRC_DIR/taglib.tar.gz" -C "$SRC_DIR"
  rm "$SRC_DIR/taglib.tar.gz"
fi

if [ ! -d "$UTFCPP_SRC" ]; then
  echo "==> Downloading utfcpp $UTFCPP_VERSION"
  curl -fsSL "https://github.com/nemtrif/utfcpp/archive/refs/tags/v$UTFCPP_VERSION.tar.gz" \
    -o "$SRC_DIR/utfcpp.tar.gz"
  tar -xzf "$SRC_DIR/utfcpp.tar.gz" -C "$SRC_DIR"
  rm "$SRC_DIR/utfcpp.tar.gz"
fi

# --- Configure & build TagLib for macOS universal -----------------------------

BUILD_MACOS="$WORK_DIR/build-macos"
rm -rf "$BUILD_MACOS" "$INSTALL_MACOS"
mkdir -p "$BUILD_MACOS"

echo "==> Configuring TagLib (macOS arm64 + x86_64)"
cmake -S "$TAGLIB_SRC" -B "$BUILD_MACOS" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_MACOS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_BINDINGS=OFF \
  -DWITH_ZLIB=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DUTF8_CPP_INCLUDE_DIR="$UTFCPP_SRC/source" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_CXX_FLAGS="-fvisibility=hidden -fvisibility-inlines-hidden" \
  > /dev/null

echo "==> Building TagLib"
cmake --build "$BUILD_MACOS" --target install --parallel "$(sysctl -n hw.ncpu)" > /dev/null

# --- Create xcframework -------------------------------------------------------

# TagLib's "main" lib is libtag.a; libtag_c.a is the C wrapper. We only need
# libtag.a since the bridge will call C++ directly.

LIB_PATH="$INSTALL_MACOS/lib/libtag.a"
HEADERS_DIR="$INSTALL_MACOS/include"

if [ ! -f "$LIB_PATH" ]; then
  echo "ERROR: $LIB_PATH not found after build" >&2
  exit 1
fi

echo "==> Packaging XCFramework"
rm -rf "$XCF_OUT"
xcodebuild -create-xcframework \
  -library "$LIB_PATH" \
  -headers "$HEADERS_DIR/taglib" \
  -output "$XCF_OUT" > /dev/null

echo "==> Done: $XCF_OUT"
ls -la "$XCF_OUT"
