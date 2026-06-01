#!/usr/bin/env bash
# Build libKeyFinder (Mixxx-Fork) + fftw3 als kombinierte statische
# .xcframework für macOS (arm64 + x86_64), iOS device (arm64) und iOS
# simulator (arm64 + x86_64).
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

# --- Build one combined variant ----------------------------------------------

build_combined_variant() {
  local name="$1"
  shift
  local extra=("$@")
  local fftw_build="$WORK_DIR/build-fftw-$name"
  local fftw_install="$WORK_DIR/install-fftw-$name"
  local kf_build="$WORK_DIR/build-kf-$name"
  local kf_install="$WORK_DIR/install-kf-$name"
  local merged="$WORK_DIR/libkeyfinder-merged-$name.a"

  rm -rf "$fftw_build" "$fftw_install" "$kf_build" "$kf_install"
  mkdir -p "$fftw_build" "$kf_build"

  echo "==> Configuring fftw ($name)" >&2
  cmake -S "$FFTW_SRC" -B "$fftw_build" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$fftw_install" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DENABLE_THREADS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "${extra[@]}" \
    > /dev/null

  echo "==> Building fftw ($name)" >&2
  cmake --build "$fftw_build" --target install --parallel "$(sysctl -n hw.ncpu)" > /dev/null

  echo "==> Configuring libKeyFinder ($name)" >&2
  # FFTW3_LIBRARY/INCLUDE_DIR explizit setzen, weil das mitgelieferte
  # FindFFTW3.cmake im iOS-Toolchain-Modus FFTW3_ROOT nicht honoriert.
  cmake -S "$KF_SRC" -B "$kf_build" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$kf_install" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_TESTS=OFF \
    -DFFTW3_ROOT="$fftw_install" \
    -DFFTW3_LIBRARY="$fftw_install/lib/libfftw3.a" \
    -DFFTW3_INCLUDE_DIR="$fftw_install/include" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "${extra[@]}" \
    > /dev/null

  echo "==> Building libKeyFinder ($name)" >&2
  cmake --build "$kf_build" --target install --parallel "$(sysctl -n hw.ncpu)" > /dev/null

  echo "==> Merging libkeyfinder + libfftw3 ($name)" >&2
  xcrun libtool -static -o "$merged" \
    "$kf_install/lib/libkeyfinder.a" \
    "$fftw_install/lib/libfftw3.a" 2> /dev/null

  printf "%s" "$merged"
}

LIB_MACOS=$(build_combined_variant "macos" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0)

LIB_IOS_DEVICE=$(build_combined_variant "ios-device" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)

LIB_IOS_SIM=$(build_combined_variant "ios-sim" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)

# Headers plattform­identisch — wir nehmen das macOS-Install.
HEADERS_DIR="$WORK_DIR/install-kf-macos/include/keyfinder"

echo "==> Packaging XCFramework"
rm -rf "$XCF_OUT"
xcodebuild -create-xcframework \
  -library "$LIB_MACOS"      -headers "$HEADERS_DIR" \
  -library "$LIB_IOS_DEVICE" -headers "$HEADERS_DIR" \
  -library "$LIB_IOS_SIM"    -headers "$HEADERS_DIR" \
  -output "$XCF_OUT" > /dev/null

echo "==> Done: $XCF_OUT"
ls "$XCF_OUT"
