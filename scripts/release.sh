#!/usr/bin/env bash
#
# release.sh — produziert ein notarisiertes, EdDSA-signiertes DMG für die
# Verteilung außerhalb des App Stores plus einen Appcast-Eintrag für Sparkle.
#
# Pipeline:
#   1) xcodebuild archive
#   2) xcodebuild -exportArchive (developer-id, hardened runtime)
#   3) Notarize .app (ZIP-Upload → notarytool wait → staple)
#   4) DMG aus stapled .app erzeugen (hdiutil)
#   5) DMG signieren (Developer ID Application)
#   6) Notarize DMG (notarytool wait → staple)
#   7) Sparkle generate_appcast über build/release/dist (signiert mit EdDSA,
#      Private-Key holt sich Sparkle aus dem Keychain).
#   8) spctl-Selbsttest für DMG und ausgepackte .app.
#
# Vor dem ersten Lauf siehe docs/DISTRIBUTION.md (Zertifikat, Notarytool-
# Profil, Sparkle-Keys, Info.plist-Platzhalter ersetzen).

set -euo pipefail

# ---------- Konfiguration -----------------------------------------------------

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

readonly PROJECT="Setify.xcodeproj"
readonly SCHEME="Setify"
readonly CONFIGURATION="Release"
readonly TEAM_ID="D75S77JA58"
readonly BUNDLE_ID="ch.beat.buehler.Setify"
readonly APP_NAME="Setify"

readonly BUILD_DIR="$PROJECT_ROOT/build/release"
readonly ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly EXPORTED_APP="$EXPORT_DIR/$APP_NAME.app"
readonly DIST_DIR="$BUILD_DIR/dist"

readonly EXPORT_OPTIONS_PLIST="$PROJECT_ROOT/scripts/ExportOptions.plist"

# Notarytool-Keychain-Profil. Einmalig erzeugen mit:
#   xcrun notarytool store-credentials AC_SETIFY \
#     --apple-id <apple-id> --team-id D75S77JA58 \
#     --password <app-specific-password>
readonly NOTARY_PROFILE="${NOTARY_PROFILE:-AC_SETIFY}"

# Optional: Sparkle. Wenn `generate_appcast` im PATH oder unter
# Sparkle_BIN_DIR liegt, wird Schritt 7 ausgeführt. Sonst übersprungen.
readonly SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

# Version aus dem Projekt ziehen, damit das DMG einen sprechenden Namen hat.
readonly MARKETING_VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' | tr -d ' ')"
readonly BUILD_NUMBER="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' | tr -d ' ')"
readonly DMG_NAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}.dmg"
readonly DMG_PATH="$DIST_DIR/$DMG_NAME"

# ---------- Helpers -----------------------------------------------------------

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Benötigter Befehl nicht gefunden: $1"
}

# ---------- Vorflug-Checks ----------------------------------------------------

log "Vorflug-Check"
require_cmd xcodebuild
require_cmd xcrun
require_cmd hdiutil
require_cmd codesign
require_cmd ditto

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    die "Kein 'Developer ID Application'-Zertifikat im Keychain. Siehe docs/DISTRIBUTION.md."
fi

# Sparkle-Placeholder dürfen nicht im Release stehen.
if grep -q "REPLACE_ME" Setify/Info.plist; then
    die "Setify/Info.plist enthält noch REPLACE_ME-Platzhalter (SUFeedURL / SUPublicEDKey). Siehe docs/DISTRIBUTION.md."
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    die "Notarytool-Profil '$NOTARY_PROFILE' nicht im Keychain. Anlegen mit 'xcrun notarytool store-credentials $NOTARY_PROFILE ...'."
fi

# ---------- 0) Workspace säubern ---------------------------------------------

log "Workspace säubern"
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR" "$DIST_DIR"

# ---------- 1) Archive --------------------------------------------------------

log "Archive (xcodebuild archive)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    archive

# ---------- 2) Export ---------------------------------------------------------

log "Export (developer-id)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR"

[ -d "$EXPORTED_APP" ] || die "Export hat kein .app erzeugt: $EXPORTED_APP"

# ---------- 3) .app notarisieren + stapeln ------------------------------------

log "ZIP für Notarytool-Upload erzeugen"
readonly APP_ZIP="$EXPORT_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$EXPORTED_APP" "$APP_ZIP"

log "Notarize .app (warten bis fertig)"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

log "Staple .app"
xcrun stapler staple "$EXPORTED_APP"
rm -f "$APP_ZIP"

# ---------- 4) DMG bauen ------------------------------------------------------

log "DMG bauen: $DMG_NAME"
readonly STAGING_DIR="$BUILD_DIR/dmg_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$EXPORTED_APP" "$STAGING_DIR/"
# Drag-zu-Applications-Komfort-Symlink.
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"
rm -rf "$STAGING_DIR"

# ---------- 5) DMG signieren --------------------------------------------------

log "DMG mit Developer ID signieren"
readonly DEVID_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[ -n "$DEVID_IDENTITY" ] || die "Developer-ID-Identity nicht auflösbar."
codesign --sign "$DEVID_IDENTITY" --timestamp "$DMG_PATH"

# ---------- 6) DMG notarisieren + stapeln -------------------------------------

log "Notarize DMG (warten bis fertig)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

log "Staple DMG"
xcrun stapler staple "$DMG_PATH"

# ---------- 7) Sparkle-Appcast aktualisieren ----------------------------------

GENERATE_APPCAST=""
if [ -n "$SPARKLE_BIN_DIR" ] && [ -x "$SPARKLE_BIN_DIR/generate_appcast" ]; then
    GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
elif command -v generate_appcast >/dev/null 2>&1; then
    GENERATE_APPCAST="$(command -v generate_appcast)"
fi

if [ -n "$GENERATE_APPCAST" ]; then
    log "Sparkle-Appcast erzeugen ($GENERATE_APPCAST)"
    # generate_appcast erwartet ein Verzeichnis mit allen Releases; wir
    # nehmen $DIST_DIR — dort liegt nur das aktuelle DMG. Wer ältere
    # Versionen im Appcast halten will, kopiert sie vorher dazu.
    "$GENERATE_APPCAST" "$DIST_DIR"
    echo "  Appcast: $DIST_DIR/appcast.xml"
else
    echo
    echo "ℹ︎  Sparkles generate_appcast nicht gefunden — Appcast nicht aktualisiert."
    echo "   Pfad mit SPARKLE_BIN_DIR=… vorgeben oder Sparkles Bin-Ordner in PATH legen."
fi

# ---------- 8) Selbsttest -----------------------------------------------------

log "spctl-Selbsttest"
spctl --assess --type install --verbose=4 "$DMG_PATH" || true
spctl --assess --type execute --verbose=4 "$EXPORTED_APP" || true

log "Fertig"
printf '  DMG:  %s\n' "$DMG_PATH"
printf '  App:  %s\n' "$EXPORTED_APP"
printf '  Version: %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
