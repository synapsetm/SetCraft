#!/usr/bin/env bash
# Build TagLib as a static library for macOS (arm64 + x86_64),
# iOS device (arm64) und iOS simulator (arm64 + x86_64),
# packaged as an .xcframework that Swift Package Manager kann konsumieren.
#
# Output: SetCraftCore/Vendor/TagLib.xcframework
#
# Requires: cmake, xcodebuild (Full Xcode, nicht nur CommandLineTools).

set -euo pipefail

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

TAGLIB_VERSION="2.3.2"
UTFCPP_VERSION="4.1.1"

# SHA-256 der Quell-Tarballs. Ohne diese Prüfung wurde hier blind entpackt und
# gebaut, was curl geliefert hat — und das Ergebnis wandert als eingecheckte
# .xcframework in jedes Release.
#
# Woher die Werte kommen: TagLib veröffentlicht keine Prüfsummen (nur den
# Tarball als Release-Asset), also sind sie beim ersten Bezug über HTTPS
# festgeschrieben. Das erkennt keinen bereits kompromittierten Erstbezug, aber
# jede spätere Änderung an der Datei — und genau darum geht es bei einem Pin.
# Beim Versions-Bump neu setzen:
#   curl -fsSL <url> | shasum -a 256
TAGLIB_SHA256="3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc"
# Achtung: GitHub-Archiv-Tarballs (`/archive/refs/tags/`) sind nicht so
# verlässlich byte-stabil wie Release-Assets — ändert GitHub einmal die
# Kompression, schlägt die Prüfung fehl, ohne dass jemand etwas manipuliert
# hat. Dann Inhalt gegen den vorhandenen Baum in `src/` vergleichen und den
# Wert neu setzen.
UTFCPP_SHA256="1ca68016f0abc24172998e39ce0d8f8e2b7a26f7579a0ff85d4e1b9a7aea56f8"

# Prüft eine heruntergeladene Datei und bricht bei Abweichung ab.
verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "FEHLER: Prüfsumme von $(basename "$file") passt nicht." >&2
    echo "  erwartet: $expected" >&2
    echo "  erhalten: $actual" >&2
    rm -f "$file"
    exit 1
  fi
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK_DIR="$HERE/build"
SRC_DIR="$HERE/src"
XCF_OUT="$REPO_ROOT/SetCraftCore/Vendor/TagLib.xcframework"

mkdir -p "$WORK_DIR" "$SRC_DIR"

TAGLIB_SRC="$SRC_DIR/taglib-$TAGLIB_VERSION"
UTFCPP_SRC="$SRC_DIR/utfcpp-$UTFCPP_VERSION"

# --- Fetch sources ------------------------------------------------------------

if [ ! -d "$TAGLIB_SRC" ]; then
  echo "==> Downloading TagLib $TAGLIB_VERSION"
  curl -fsSL "https://github.com/taglib/taglib/releases/download/v$TAGLIB_VERSION/taglib-$TAGLIB_VERSION.tar.gz" \
    -o "$SRC_DIR/taglib.tar.gz"
  verify_sha256 "$SRC_DIR/taglib.tar.gz" "$TAGLIB_SHA256"
  tar -xzf "$SRC_DIR/taglib.tar.gz" -C "$SRC_DIR"
  rm "$SRC_DIR/taglib.tar.gz"
fi

if [ ! -d "$UTFCPP_SRC" ]; then
  echo "==> Downloading utfcpp $UTFCPP_VERSION"
  curl -fsSL "https://github.com/nemtrif/utfcpp/archive/refs/tags/v$UTFCPP_VERSION.tar.gz" \
    -o "$SRC_DIR/utfcpp.tar.gz"
  verify_sha256 "$SRC_DIR/utfcpp.tar.gz" "$UTFCPP_SHA256"
  tar -xzf "$SRC_DIR/utfcpp.tar.gz" -C "$SRC_DIR"
  rm "$SRC_DIR/utfcpp.tar.gz"
fi

# TagLib 2.x sucht utfcpp im 3rdparty-Unterverzeichnis (das im Tarball
# als leere Submodul-Hülle vorliegt). Bestücke es mit dem entpackten
# Quellbaum, sonst kann CMake utfcpp nicht finden.
if [ ! -f "$TAGLIB_SRC/3rdparty/utfcpp/CMakeLists.txt" ]; then
  echo "==> Seeding 3rdparty/utfcpp from $(basename "$UTFCPP_SRC")"
  rm -rf "$TAGLIB_SRC/3rdparty/utfcpp"
  cp -R "$UTFCPP_SRC" "$TAGLIB_SRC/3rdparty/utfcpp"
fi

# --- Build one TagLib variant -------------------------------------------------

build_taglib_variant() {
  local name="$1"
  local build_dir="$WORK_DIR/build-$name"
  local install_dir="$WORK_DIR/install-$name"
  shift
  local extra=("$@")

  rm -rf "$build_dir" "$install_dir"
  mkdir -p "$build_dir"

  echo "==> Configuring TagLib ($name)" >&2
  cmake -S "$TAGLIB_SRC" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BINDINGS=OFF \
    -DWITH_ZLIB=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DUTF8_CPP_INCLUDE_DIR="$UTFCPP_SRC/source" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="-fvisibility=hidden -fvisibility-inlines-hidden" \
    "${extra[@]}" \
    > /dev/null

  echo "==> Building TagLib ($name)" >&2
  cmake --build "$build_dir" --target install --parallel "$(sysctl -n hw.ncpu)" > /dev/null

  printf "%s" "$install_dir/lib/libtag.a"
}

LIB_MACOS=$(build_taglib_variant "macos" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0)

LIB_IOS_DEVICE=$(build_taglib_variant "ios-device" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)

LIB_IOS_SIM=$(build_taglib_variant "ios-sim" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)

# --- Package as XCFramework ---------------------------------------------------

# Header-Verzeichnis ist plattform­identisch — wir nehmen das macOS-Install.
HEADERS_DIR="$WORK_DIR/install-macos/include/taglib"

echo "==> Packaging XCFramework"
rm -rf "$XCF_OUT"
xcodebuild -create-xcframework \
  -library "$LIB_MACOS"      -headers "$HEADERS_DIR" \
  -library "$LIB_IOS_DEVICE" -headers "$HEADERS_DIR" \
  -library "$LIB_IOS_SIM"    -headers "$HEADERS_DIR" \
  -output "$XCF_OUT" > /dev/null

echo "==> Done: $XCF_OUT"
ls "$XCF_OUT"
