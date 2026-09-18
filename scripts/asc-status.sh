#!/usr/bin/env bash
#
# asc-status.sh — fragt App Store Connect nach dem Zustand der hochgeladenen
# iOS-Builds, ohne Browser.
#
# Beantwortet die zwei Fragen, die nach einem Upload anstehen:
#   * Ist der Build fertig verarbeitet (PROCESSING -> VALID) und nicht abgelaufen?
#   * Traegt er ein App-Icon? (`iconAssetToken`; fehlt es, zeigt TestFlight ein
#     graues Gitter.)
# Zusaetzlich: welcher Build an der App-Store-Version haengt. Haengt dort keiner,
# bleibt die Kopfzeile in App Store Connect ohne Icon — das ist erwartetes
# Verhalten bei reiner TestFlight-Verteilung und kein Build-Fehler.
#
# Auth wie in release-ios.sh: API-Key-ID und Issuer-ID aus
# ~/.appstoreconnect/setcraft.env (oder via ENV), Private Key unter
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#
# Usage:
#   scripts/asc-status.sh              # letzte 5 Builds
#   scripts/asc-status.sh -n 10        # letzte 10
#   scripts/asc-status.sh -b <bundle>  # andere Bundle-ID

set -euo pipefail

readonly BUNDLE_ID_DEFAULT="ch.buehler.beat.SetCraft.iOS"

bundle_id="$BUNDLE_ID_DEFAULT"
limit=5

while getopts "b:n:h" opt; do
    case "$opt" in
        b) bundle_id="$OPTARG" ;;
        n) limit="$OPTARG" ;;
        h) sed -n '3,22p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

log()  { printf '\n\033[1;34m> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# ---------- Auth --------------------------------------------------------------

# Key-ID, Issuer-ID, JWT und der curl-Wrapper `asc_api` kommen aus dem
# gemeinsamen Helfer — dieselbe Auth wie in asc-create-distribution-cert.sh.
# shellcheck source=scripts/asc-auth.sh
source "$(dirname "${BASH_SOURCE[0]}")/asc-auth.sh"

api() { asc_api "$1" || fail "API-Aufruf fehlgeschlagen: $1"; }

# ---------- Abfragen ----------------------------------------------------------

log "App suchen: $bundle_id"
app_json="$(api "/v1/apps?filter%5BbundleId%5D=$bundle_id")"
app_id="$(jq -r '.data[0].id // empty' <<<"$app_json")"
[ -n "$app_id" ] || fail "Keine App mit Bundle-ID $bundle_id gefunden."
jq -r '.data[0] | "   \(.attributes.name)  (id \(.id))"' <<<"$app_json"

log "Builds (neueste zuerst)"
api "/v1/builds?filter%5Bapp%5D=$app_id&limit=$limit&sort=-version" | jq -r '
    .data[] | .attributes as $a
    | "   Build \($a.version)  \($a.processingState)"
      + "  hochgeladen \($a.uploadedDate[:16] | sub("T"; " "))"
      + (if $a.expired then "  [abgelaufen]" else "" end)
      + (if $a.iconAssetToken then "" else "  [OHNE ICON]" end)'

log "App-Store-Versionen"
versions="$(api "/v1/apps/$app_id/appStoreVersions?limit=5")"
while read -r version_id version_string state; do
    [ -n "$version_id" ] || continue
    linked="$(api "/v1/appStoreVersions/$version_id/build" \
              | jq -r '.data.attributes.version // "keiner"')"
    printf '   %-8s %-24s Build: %s\n' "$version_string" "$state" "$linked"
done < <(jq -r '.data[] | "\(.id) \(.attributes.versionString) \(.attributes.appVersionState // .attributes.appStoreState)"' <<<"$versions")

cat <<'NOTE'

   Haengt an der App-Store-Version kein Build, zeigt App Store Connect in der
   Kopfzeile ein graues Platzhalter-Icon. Das ist bei reiner TestFlight-
   Verteilung normal und sagt nichts ueber den Build aus — fuer TestFlight
   zaehlt allein das Icon des Builds (oben als OHNE ICON markiert, falls es
   fehlt).
NOTE
