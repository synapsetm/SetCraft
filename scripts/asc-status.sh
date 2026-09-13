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
readonly ASC_ENV_FILE="$HOME/.appstoreconnect/setcraft.env"
readonly API="https://api.appstoreconnect.apple.com"

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

if [ -f "$ASC_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ASC_ENV_FILE"
fi
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID fehlt (ENV oder ~/.appstoreconnect/setcraft.env)}"
: "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID fehlt (ENV oder ~/.appstoreconnect/setcraft.env)}"

readonly KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
[ -f "$KEY_PATH" ] || fail "Private Key nicht gefunden: $KEY_PATH"

# ES256-JWT. Die Signatur kommt von openssl als DER-Sequenz und muss fuer JWS in
# rohe r||s (2x32 Byte) umgeschrieben werden — dafuer ein paar Zeilen Python,
# weil weder PyJWT noch `cryptography` auf dem Rechner installiert sind.
token="$(ASC_KEY="$KEY_PATH" KID="$ASC_API_KEY_ID" ISS="$ASC_API_ISSUER_ID" python3 - <<'PY'
import base64, json, os, subprocess, time

def b64(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")

header  = b64(json.dumps({"alg": "ES256", "kid": os.environ["KID"], "typ": "JWT"}).encode())
payload = b64(json.dumps({"iss": os.environ["ISS"],
                          "iat": int(time.time()),
                          "exp": int(time.time()) + 600,
                          "aud": "appstoreconnect-v1"}).encode())
signing_input = header + b"." + payload

der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY"]],
                     input=signing_input, capture_output=True, check=True).stdout

# DER: SEQUENCE { INTEGER r, INTEGER s } -> r||s, je auf 32 Byte aufgefuellt.
i = 2 if der[1] < 0x80 else 3
parts = []
for _ in range(2):
    assert der[i] == 0x02, "unerwartete DER-Struktur"
    length = der[i + 1]
    parts.append(der[i + 2:i + 2 + length].lstrip(b"\x00").rjust(32, b"\x00"))
    i += 2 + length

print((signing_input + b"." + b64(b"".join(parts))).decode())
PY
)"

api() {
    curl -fsS -H "Authorization: Bearer $token" "$API$1" \
        || fail "API-Aufruf fehlgeschlagen: $1"
}

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
