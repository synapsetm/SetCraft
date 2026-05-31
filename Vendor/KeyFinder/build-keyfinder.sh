#!/usr/bin/env bash
# Build libKeyFinder (Mixxx-Fork) + die benötigte fftw3-Abhängigkeit als
# universelle macOS-.xcframework. libKeyFinder wird statisch mit fftw3
# gelinkt; die beiden Archive werden zu einem zusammengeführt, damit das
# xcframework genau eine Library pro Plattform enthält.
#
# Output: SetifyCore/Vendor/KeyFinder.xcframework
#
# Requires: cmake, xcodebuild (Xcode, nicht nur CommandLineTools).

set -euo pipefail

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

FFTW_VERSION="3.3.10"
KEYFINDER_VERSION="2.2.6"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK_DIR="$HERE/build"
SRC_DIR="$HERE/src"
FFTW_SRC="$SRC_DIR/fftw-$FFTW_VERSION"
KF_SRC="$SRC_DIR/libkeyfinder-$KEYFINDER_VERSION"
FFTW_INSTALL="$WORK_DIR/install-fftw"
KF_INSTALL="$WORK_DIR/install-keyfinder"
XCF_OUT="$REPO_ROOT/SetifyCore/Vendor/KeyFinder.xcframework"

mkdir -p "$WORK_DIR" "$SRC_DIR"

# --- Fetch sources ------------------------------------------------------------

if [ ! -d "$FFTW_SRC" ]; then
  echo "==> Downloading fftw $FFTW_VERSION"
  curl -fsSL "https://www.fftw.org/fftw-$FFTW_VERSION.tar.gz" -o "$SRC_DIR/fftw.tar.gz"
  tar -xzf "$SRC_DIR/fftw.tar.gz" -C "$SRC_DIR"
  rm "$SRC_DIR/fftw.tar.gz"
fi

if [ ! -d "$KF_SRC" ]; then
  echo "==> Downloading libKeyFinder $KEYFINDER_VERSION"
  curl -fsSL "https://github.com/mixxxdj/libkeyfinder/archive/refs/tags/v$KEYFINDER_VERSION.tar.gz" \
    -o "$SRC_DIR/keyfinder.tar.gz"
  tar -xzf "$SRC_DIR/keyfinder.tar.gz" -C "$SRC_DIR"
  rm "$SRC_DIR/keyfinder.tar.gz"
fi

# --- Build fftw3 (double precision, static, universal) -------------------------

FFTW_BUILD="$WORK_DIR/build-fftw"
rm -rf "$FFTW_BUILD" "$FFTW_INSTALL"
mkdir -p "$FFTW_BUILD"

echo "==> Configuring fftw"
cmake -S "$FFTW_SRC" -B "$FFTW_BUILD" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_INSTALL_PREFIX="$FFTW_INSTALL" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTS=OFF \
  -DENABLE_THREADS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  > /dev/null

echo "==> Building fftw"
cmake --build "$FFTW_BUILD" --target install --parallel "$(sysctl -n hw.ncpu)" > /dev/null

# --- Build libKeyFinder (static, universal, linked against the staged fftw) --

KF_BUILD="$WORK_DIR/build-keyfinder"
rm -rf "$KF_BUILD" "$KF_INSTALL"
mkdir -p "$KF_BUILD"

echo "==> Configuring libKeyFinder"
cmake -S "$KF_SRC" -B "$KF_BUILD" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_INSTALL_PREFIX="$KF_INSTALL" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_TESTS=OFF \
  -DFFTW3_ROOT="$FFTW_INSTALL" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  > /dev/null

echo "==> Building libKeyFinder"
cmake --build "$KF_BUILD" --target install --parallel "$(sysctl -n hw.ncpu)" > /dev/null

# --- Merge fftw3 + keyfinder into one static archive --------------------------

MERGED="$WORK_DIR/libkeyfinder-merged.a"
echo "==> Merging libkeyfinder.a + libfftw3.a → $(basename "$MERGED")"
xcrun libtool -static -o "$MERGED" \
  "$KF_INSTALL/lib/libkeyfinder.a" \
  "$FFTW_INSTALL/lib/libfftw3.a"

# --- Package as XCFramework ---------------------------------------------------

HEADERS_DIR="$KF_INSTALL/include/keyfinder"

echo "==> Packaging XCFramework"
rm -rf "$XCF_OUT"
xcodebuild -create-xcframework \
  -library "$MERGED" \
  -headers "$HEADERS_DIR" \
  -output "$XCF_OUT" > /dev/null

echo "==> Done: $XCF_OUT"
ls -la "$XCF_OUT"
