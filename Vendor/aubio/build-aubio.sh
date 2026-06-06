#!/usr/bin/env bash
# Build aubio 0.4.9 as a static library for macOS (arm64 + x86_64),
# iOS device (arm64) und iOS simulator (arm64 + x86_64) — als
# universelle .xcframework.
#
# Output: SetCraftCore/Vendor/aubio.xcframework
#
# Requires:
#  - /opt/homebrew/bin/python3.11 (aubio's bundled waf ist nicht
#    Python-3.12+-fest; siehe README.md).
#  - Full Xcode (für xcodebuild -create-xcframework und iOS SDKs).
#  - Internet beim ersten Lauf.

set -euo pipefail

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

PYTHON="${SETCRAFT_PYTHON:-/opt/homebrew/bin/python3.11}"
if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Python 3.11 fehlt: $PYTHON" >&2
  echo "       brew install python@3.11" >&2
  exit 1
fi

AUBIO_VERSION="0.4.9"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK_DIR="$HERE/build"
SRC_DIR="$HERE/src"
SRC="$SRC_DIR/aubio-$AUBIO_VERSION"
XCF_OUT="$REPO_ROOT/SetCraftCore/Vendor/aubio.xcframework"

mkdir -p "$SRC_DIR"

# --- Fetch sources ------------------------------------------------------------

if [ ! -d "$SRC" ]; then
  echo "==> Downloading aubio $AUBIO_VERSION"
  curl -fsSL "https://aubio.org/pub/aubio-$AUBIO_VERSION.tar.bz2" -o "$SRC_DIR/aubio.tar.bz2"
  tar -xjf "$SRC_DIR/aubio.tar.bz2" -C "$SRC_DIR"
  rm "$SRC_DIR/aubio.tar.bz2"
fi

# Aubio 0.4.9 bringt ein altes waf mit, das mit Python >=3.12 nicht läuft.
if [ ! -f "$SRC/.waf-replaced" ]; then
  echo "==> Replacing bundled waf with current upstream"
  curl -fsSL "https://waf.io/waf-2.1.6" -o "$SRC/waf"
  chmod +x "$SRC/waf"
  rm -rf "$SRC/waflib"
  touch "$SRC/.waf-replaced"
fi

# aubio's tests/create_tests_source.py wird vom Build mit `python` (ohne 3)
# aufgerufen. Stelle einen lokalen Symlink bereit.
mkdir -p "$WORK_DIR/pyalias"
ln -sf "$PYTHON" "$WORK_DIR/pyalias/python"

# --- Build one variant --------------------------------------------------------

build_aubio_variant() {
  local name="$1"
  local cflags="$2"
  local ldflags="$3"
  local prefix="$WORK_DIR/install-$name"
  local stage="$WORK_DIR/stage-$name"

  echo "==> Configuring aubio ($name)" >&2
  cd "$SRC"
  "$PYTHON" waf distclean > /dev/null 2>&1 || true
  CFLAGS="$cflags" LDFLAGS="$ldflags" \
    "$PYTHON" waf configure --prefix="$prefix" \
      --disable-sndfile --disable-avcodec --disable-samplerate \
      --disable-jack --disable-docs --disable-tests --disable-examples \
      > /dev/null

  echo "==> Building aubio ($name)" >&2
  PATH="$WORK_DIR/pyalias:$PATH" "$PYTHON" waf build > /dev/null

  rm -rf "$stage"
  PATH="$WORK_DIR/pyalias:$PATH" "$PYTHON" waf install --destdir="$stage" > /dev/null

  printf "%s" "$stage$prefix/lib/libaubio.a"
}

IOS_SDK_DEVICE="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_SDK_SIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"

LIB_MACOS=$(build_aubio_variant "macos" \
  "-arch arm64 -arch x86_64 -mmacosx-version-min=12.0" \
  "-arch arm64 -arch x86_64 -mmacosx-version-min=12.0")

LIB_IOS_DEVICE=$(build_aubio_variant "ios-device" \
  "-arch arm64 -isysroot $IOS_SDK_DEVICE -mios-version-min=14.0" \
  "-arch arm64 -isysroot $IOS_SDK_DEVICE -mios-version-min=14.0")

LIB_IOS_SIM=$(build_aubio_variant "ios-sim" \
  "-arch arm64 -arch x86_64 -isysroot $IOS_SDK_SIM -mios-simulator-version-min=14.0" \
  "-arch arm64 -arch x86_64 -isysroot $IOS_SDK_SIM -mios-simulator-version-min=14.0")

HEADERS_SRC="$WORK_DIR/stage-macos$WORK_DIR/install-macos/include/aubio"
# Falls die obigen verschachtelten Pfade nicht stimmen, fallback:
if [ ! -d "$HEADERS_SRC" ]; then
  HEADERS_SRC=$(find "$WORK_DIR/stage-macos" -type d -name "aubio" | head -1)
fi

cd "$REPO_ROOT"
echo "==> Packaging XCFramework"
rm -rf "$XCF_OUT"
xcodebuild -create-xcframework \
  -library "$LIB_MACOS"      -headers "$HEADERS_SRC" \
  -library "$LIB_IOS_DEVICE" -headers "$HEADERS_SRC" \
  -library "$LIB_IOS_SIM"    -headers "$HEADERS_SRC" \
  -output "$XCF_OUT" > /dev/null

echo "==> Done: $XCF_OUT"
ls "$XCF_OUT"
