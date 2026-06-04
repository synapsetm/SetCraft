#!/bin/sh
#
# sc-push — push a folder of audio files into the booted iOS Simulator's
# SetCraft iOS sandbox at `Documents/<folder-name>`.
#
# After running, the folder shows up in the Files app under
# "On My iPhone → SetCraft iOS → Documents → <folder-name>" and is
# pickable inside SetCraft via "Open folder…".
#
# Usage:
#   ./scripts/sc-push.sh                  # uses ~/Downloads/Testmusik
#   ./scripts/sc-push.sh ~/Music/Test     # uses the given source folder
#
# Voraussetzungen:
#   - Xcode unter /Applications/Xcode.app (sonst DEVELOPER_DIR setzen)
#   - genau einer Simulator gebootet, SetCraft iOS einmal aus Xcode
#     installiert (sonst kennt simctl die Bundle-ID nicht).

set -eu

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUNDLE_ID="ch.buehler.beat.SetCraft.iOS"
SRC="${1:-$HOME/Downloads/Testmusik}"

if [ ! -d "$SRC" ]; then
    echo "Source folder does not exist: $SRC" >&2
    exit 1
fi

SRC_NAME="$(basename "$SRC")"

APP_DATA="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)" || {
    echo "Couldn't find $BUNDLE_ID on the booted Simulator." >&2
    echo "Make sure a Simulator is booted and SetCraft iOS is installed (Cmd-R once in Xcode)." >&2
    exit 1
}

DEST="$APP_DATA/Documents/$SRC_NAME"

echo "Source: $SRC"
echo "Dest:   $DEST"
echo

mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"

echo "Inhalt:"
ls "$DEST"
echo
echo "In SetCraft picken: ••• → Open folder… → On My iPhone → SetCraft iOS → Documents → $SRC_NAME"
