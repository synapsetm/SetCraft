#!/usr/bin/env bash
#
# release-ios.sh — baut SetCraft iOS als Release-Archive, exportiert das IPA
# mit App-Store-Connect-Provisioning und lädt es per altool an App Store
# Connect (TestFlight Internal Testing).
#
# Vor dem ersten Lauf:
#   - App in App Store Connect angelegt (Bundle ch.buehler.beat.SetCraft.iOS)
#   - API Key (.p8) unter ~/.appstoreconnect/private_keys/AuthKey_<KEY>.p8
#   - ENV: ASC_API_KEY_ID, ASC_API_ISSUER_ID
#
# Usage:
#   ASC_API_KEY_ID=ABC123... ASC_API_ISSUER_ID=uuid... ./scripts/release-ios.sh
#
# Build-Number kann per ENV überschrieben werden:
#   BUILD_NUMBER=7 ./scripts/release-ios.sh   # ansonsten: pbxproj-Wert + 0

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

readonly PROJECT="SetCraft.xcodeproj"
readonly SCHEME="SetCraft iOS"
readonly CONFIGURATION="Release"
readonly BUNDLE_ID="ch.buehler.beat.SetCraft.iOS"
readonly TEAM_ID="D75S77JA58"

readonly BUILD_DIR="$PROJECT_ROOT/build/ios"
readonly ARCHIVE_PATH="$BUILD_DIR/SetCraft-iOS.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly EXPORT_OPTIONS_PLIST="$PROJECT_ROOT/scripts/ExportOptions-iOS.plist"

# ---------- Auth ------------------------------------------------------------

: "${ASC_API_KEY_ID:?ENV ASC_API_KEY_ID fehlt — z. B. ASC_API_KEY_ID=ABC123...}"
: "${ASC_API_ISSUER_ID:?ENV ASC_API_ISSUER_ID fehlt — UUID aus App Store Connect}"

# altool sucht ~/.appstoreconnect/private_keys/AuthKey_<KEY>.p8 automatisch.
readonly KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
[ -f "$KEY_PATH" ] || {
    echo "✖ API-Key nicht gefunden: $KEY_PATH" >&2
    echo "  Lade die .p8-Datei von App Store Connect und lege sie dorthin." >&2
    exit 1
}

# ---------- Versionen ------------------------------------------------------

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }

MARKETING_VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/^ *MARKETING_VERSION/ {print $2; exit}' | tr -d ' ')"
CURRENT_BUILD="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/^ *CURRENT_PROJECT_VERSION/ {print $2; exit}' | tr -d ' ')"
BUILD_NUMBER="${BUILD_NUMBER:-$CURRENT_BUILD}"

log "Version: $MARKETING_VERSION (build $BUILD_NUMBER)"
log "Bundle:  $BUNDLE_ID"

# ---------- 1) Archive -----------------------------------------------------

log "Archive bauen …"
rm -rf "$ARCHIVE_PATH"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

# ---------- 2) Export IPA --------------------------------------------------

log "IPA exportieren …"
rm -rf "$EXPORT_DIR"

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$ASC_API_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"

IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$IPA_PATH" ] || { echo "✖ kein IPA gefunden in $EXPORT_DIR" >&2; exit 1; }
log "IPA: $IPA_PATH"

# ---------- 3) Upload an App Store Connect --------------------------------

log "Upload an App Store Connect (TestFlight) …"
xcrun altool --upload-app \
    -f "$IPA_PATH" \
    -t ios \
    --apiKey "$ASC_API_KEY_ID" \
    --apiIssuer "$ASC_API_ISSUER_ID"

cat <<EOF

✔ Upload abgeschlossen.

Nächste Schritte:
  1. App Store Connect → TestFlight → Builds
  2. Processing dauert ~5–15 Minuten (Mail von Apple, wenn fertig)
  3. Internal Testing: dich selbst als Tester hinzufügen (falls noch nicht)
  4. Auf dem iPhone die TestFlight-App starten → SetCraft installieren

Build: $MARKETING_VERSION ($BUILD_NUMBER)
EOF
