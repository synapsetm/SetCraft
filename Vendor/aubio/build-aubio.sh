#!/usr/bin/env bash
# Build aubio 0.4.9 as a static library for macOS (arm64 + x86_64) and package
# it as an .xcframework. aubio nutzt vDSP (Apple Accelerate) für FFT — keine
# fftw3-Abhängigkeit nötig.
#
# Output: SetifyCore/Vendor/aubio.xcframework
#
# Requires:
#  - /opt/homebrew/bin/python3.11 (aubio's bundled waf ist nicht
#    Python-3.12+-fest; siehe README.md neben diesem Skript).
#  - Full Xcode (für xcodebuild -create-xcframework).
#  - Internet beim ersten Lauf (Quelltarball).

set -euo pipefail

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

PYTHON="${SETIFY_PYTHON:-/opt/homebrew/bin/python3.11}"
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
STAGE="$WORK_DIR/stage"
XCF_OUT="$REPO_ROOT/SetifyCore/Vendor/aubio.xcframework"

mkdir -p "$SRC_DIR"

# --- Fetch sources ------------------------------------------------------------

if [ ! -d "$SRC" ]; then
  echo "==> Downloading aubio $AUBIO_VERSION"
  curl -fsSL "https://aubio.org/pub/aubio-$AUBIO_VERSION.tar.bz2" -o "$SRC_DIR/aubio.tar.bz2"
  tar -xjf "$SRC_DIR/aubio.tar.bz2" -C "$SRC_DIR"
  rm "$SRC_DIR/aubio.tar.bz2"
fi

# Aubio 0.4.9 bringt ein altes waf mit, das mit Python >=3.12 nicht läuft
# (imp-Modul, 'rU'-Modus). Ersetze waflib durch waf 2.x.
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

# --- Configure & build --------------------------------------------------------

cd "$SRC"
"$PYTHON" waf distclean > /dev/null 2>&1 || true

echo "==> Configuring aubio (arm64 + x86_64, vDSP FFT)"
CFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0" \
LDFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0" \
"$PYTHON" waf configure --prefix="/tmp/aubio-stage-prefix" \
  --disable-sndfile --disable-avcodec --disable-samplerate \
  --disable-jack --disable-docs --disable-tests --disable-examples \
  > /dev/null

echo "==> Building aubio"
PATH="$WORK_DIR/pyalias:$PATH" "$PYTHON" waf build > /dev/null

rm -rf "$STAGE"
echo "==> Installing aubio into $STAGE"
PATH="$WORK_DIR/pyalias:$PATH" "$PYTHON" waf install --destdir="$STAGE" > /dev/null

LIB="$STAGE/tmp/aubio-stage-prefix/lib/libaubio.a"
HEADERS_SRC="$STAGE/tmp/aubio-stage-prefix/include/aubio"

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found after install" >&2
  exit 1
fi

# --- Package as XCFramework ---------------------------------------------------

cd "$REPO_ROOT"
echo "==> Packaging XCFramework"
rm -rf "$XCF_OUT"
xcodebuild -create-xcframework \
  -library "$LIB" \
  -headers "$HEADERS_SRC" \
  -output "$XCF_OUT" > /dev/null

echo "==> Done: $XCF_OUT"
ls -la "$XCF_OUT"
