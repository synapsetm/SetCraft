#!/usr/bin/env bash
#
# release.sh — produziert ein notarisiertes, EdDSA-signiertes DMG für die
# Verteilung außerhalb des App Stores, lädt es als GitHub-Release-Asset hoch
# und aktualisiert den via GitHub Pages gehosteten Sparkle-Appcast.
#
# Pipeline:
#   1) xcodebuild archive
#   2) xcodebuild -exportArchive (developer-id, hardened runtime)
#   3) Notarize .app (ZIP-Upload → notarytool wait → staple)
#   4) DMG aus stapled .app erzeugen (hdiutil)
#   5) DMG signieren (Developer ID Application)
#   6) Notarize DMG (notarytool wait → staple)
#   7) gh release create v<version>-<build> mit DMG als Asset
#   8) Sparkle generate_appcast (signiert mit EdDSA-Key aus Keychain,
#      --download-url-prefix zeigt auf den GitHub-Release-Asset-Pfad),
#      Ergebnis nach docs/appcast.xml committen + pushen.
#   9) spctl-Selbsttest für DMG und ausgepackte .app.
#
# Vor dem ersten Lauf siehe docs/DISTRIBUTION.md (Zertifikat, Notarytool-
# Profil, Sparkle-Keys, GitHub-Pages aktivieren, gh auth login).

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

# Sparkle. Wenn `generate_appcast` im PATH oder unter SPARKLE_BIN_DIR liegt,
# wird Schritt 7 ausgeführt. Andernfalls schlägt das Skript fehl, weil ohne
# Appcast kein Auto-Update funktioniert.
readonly SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

# GitHub-Repo, in dem das DMG als Release-Asset landet und an dessen
# Pages-Site `docs/appcast.xml` ausgeliefert wird.
readonly REPO_SLUG="${REPO_SLUG:-synapsetm/Setify}"

# Version aus dem Projekt ziehen, damit das DMG einen sprechenden Namen hat.
readonly MARKETING_VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' | tr -d ' ')"
readonly BUILD_NUMBER="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' | tr -d ' ')"
readonly DMG_NAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}.dmg"
readonly DMG_PATH="$DIST_DIR/$DMG_NAME"
readonly RELEASE_TAG="v${MARKETING_VERSION}-${BUILD_NUMBER}"
readonly DOWNLOAD_URL_PREFIX="https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}/"
readonly APPCAST_PUBLISHED_PATH="$PROJECT_ROOT/docs/appcast.xml"

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
require_cmd git
require_cmd gh

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

if ! gh auth status >/dev/null 2>&1; then
    die "GitHub CLI nicht eingeloggt. 'gh auth login' ausführen (Scope 'repo' nötig)."
fi

if ! gh repo view "$REPO_SLUG" >/dev/null 2>&1; then
    die "Kein Zugriff auf GitHub-Repo $REPO_SLUG. REPO_SLUG=eigen/repo ./scripts/release.sh nutzen oder Default anpassen."
fi

# Sparkle-CLI lokalisieren (zwingend erforderlich für signierten Appcast).
GENERATE_APPCAST=""
if [ -n "$SPARKLE_BIN_DIR" ] && [ -x "$SPARKLE_BIN_DIR/generate_appcast" ]; then
    GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
elif command -v generate_appcast >/dev/null 2>&1; then
    GENERATE_APPCAST="$(command -v generate_appcast)"
else
    AUTO_SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type d -name 'Sparkle' -path '*/artifacts/*/bin' 2>/dev/null | head -1)"
    if [ -n "$AUTO_SPARKLE_BIN" ] && [ -x "$AUTO_SPARKLE_BIN/generate_appcast" ]; then
        GENERATE_APPCAST="$AUTO_SPARKLE_BIN/generate_appcast"
    fi
fi
[ -n "$GENERATE_APPCAST" ] || die "Sparkles 'generate_appcast' nicht gefunden. SPARKLE_BIN_DIR=... oder einmal in Xcode 'Resolve Package Dependencies' ausführen."
readonly GENERATE_APPCAST

# GitHub-Release-Tag landet am Tip des aktuellen Branches. Damit der Tag am
# erwarteten Commit haengt, muessen lokale Commits gepusht sein und es darf
# kein detached HEAD vorliegen.
readonly CURRENT_BRANCH="$(git branch --show-current)"
[ -n "$CURRENT_BRANCH" ] || die "Detached HEAD — bitte auf einem Branch (z. B. main) releasen."

if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    AHEAD="$(git rev-list --count '@{u}..HEAD')"
    if [ "$AHEAD" -gt 0 ]; then
        die "$AHEAD lokale(r) Commit(s) noch nicht gepusht. Erst 'git push' ausfuehren, damit das GitHub-Release am richtigen Commit haengt."
    fi
fi

# Ungetrackte/ungespeicherte Aenderungen ausserhalb von docs/appcast.xml warnen,
# aber nicht blockieren — das Skript committet nur die Appcast-Datei selbst.
if [ -n "$(git status --porcelain | grep -v 'docs/appcast.xml' || true)" ]; then
    log "Hinweis: Working Copy hat unsaubere Aenderungen ausserhalb von docs/appcast.xml — die werden nicht committet."
fi

# Sicher gehen, dass der Release-Tag noch nicht existiert (sonst zeigt er auf
# einen alten Commit). Idempotenz via 'gh release upload --clobber' weiter unten.
if git rev-parse "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
    die "Git-Tag $RELEASE_TAG existiert bereits lokal. Version anheben oder Tag entfernen."
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

# ---------- 7) GitHub-Release anlegen / DMG hochladen ------------------------

log "GitHub-Release $RELEASE_TAG vorbereiten ($REPO_SLUG)"
if gh release view "$RELEASE_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    log "Release $RELEASE_TAG existiert — DMG ueberschreiben"
    gh release upload "$RELEASE_TAG" "$DMG_PATH" --repo "$REPO_SLUG" --clobber
else
    log "Release $RELEASE_TAG erstellen und DMG hochladen"
    gh release create "$RELEASE_TAG" "$DMG_PATH" \
        --repo "$REPO_SLUG" \
        --target "$CURRENT_BRANCH" \
        --title "Setify $MARKETING_VERSION" \
        --notes "Setify $MARKETING_VERSION (build $BUILD_NUMBER)"
fi

# ---------- 8) Sparkle-Appcast erzeugen + via Pages veröffentlichen ----------

log "Sparkle-Appcast erzeugen (Download-URL-Prefix: $DOWNLOAD_URL_PREFIX)"
# generate_appcast scannt $DIST_DIR (enthält nur die frische DMG), signiert mit
# EdDSA-Key aus dem Keychain, und schreibt $DIST_DIR/appcast.xml.
"$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$DIST_DIR"

[ -f "$DIST_DIR/appcast.xml" ] || die "generate_appcast hat keine appcast.xml erzeugt."

log "Appcast nach docs/ kopieren und pushen"
mkdir -p "$(dirname "$APPCAST_PUBLISHED_PATH")"
cp "$DIST_DIR/appcast.xml" "$APPCAST_PUBLISHED_PATH"

git add "$APPCAST_PUBLISHED_PATH"
if git diff --cached --quiet -- "$APPCAST_PUBLISHED_PATH"; then
    log "docs/appcast.xml unveraendert — kein Commit noetig"
else
    git commit -m "release(${RELEASE_TAG}): appcast aktualisieren"
    git push origin HEAD
fi

# ---------- 9) Selbsttest -----------------------------------------------------

log "spctl-Selbsttest"
spctl --assess --type install --verbose=4 "$DMG_PATH" || true
spctl --assess --type execute --verbose=4 "$EXPORTED_APP" || true

log "Fertig"
printf '  Tag:     %s\n' "$RELEASE_TAG"
printf '  DMG:     %s\n' "$DMG_PATH"
printf '  Asset:   %s%s\n' "$DOWNLOAD_URL_PREFIX" "$DMG_NAME"
printf '  Appcast: %s\n' "$APPCAST_PUBLISHED_PATH"
printf '  Version: %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
