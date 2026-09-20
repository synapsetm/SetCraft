#!/usr/bin/env bash
#
# asc-auth.sh — gemeinsame App-Store-Connect-Authentifizierung.
# Wird von den anderen asc-*-Skripten *gesourct*, nicht ausgefuehrt.
#
# Setzt nach dem Sourcen:
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID   (aus ENV oder ~/.appstoreconnect/setcraft.env)
#   ASC_KEY_PATH                        (Pfad zur .p8)
#   ASC_TOKEN                           (ES256-JWT, 10 Minuten gueltig)
#   asc_api <pfad>                      (curl-Wrapper, gibt JSON auf stdout)

readonly ASC_ENV_FILE="${ASC_ENV_FILE:-$HOME/.appstoreconnect/setcraft.env}"
readonly ASC_API="https://api.appstoreconnect.apple.com"

if [ -f "$ASC_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ASC_ENV_FILE"
fi
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID fehlt (ENV oder ~/.appstoreconnect/setcraft.env)}"
: "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID fehlt (ENV oder ~/.appstoreconnect/setcraft.env)}"

ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
[ -f "$ASC_KEY_PATH" ] || {
    printf '\033[1;31mPrivate Key nicht gefunden: %s\033[0m\n' "$ASC_KEY_PATH" >&2
    return 1 2>/dev/null || exit 1
}

# ES256-JWT. Die Signatur kommt von openssl als DER-Sequenz und muss fuer JWS in
# rohe r||s (2x32 Byte) umgeschrieben werden — dafuer ein paar Zeilen Python,
# weil weder PyJWT noch `cryptography` auf dem Rechner installiert sind.
ASC_TOKEN="$(ASC_KEY="$ASC_KEY_PATH" KID="$ASC_API_KEY_ID" ISS="$ASC_API_ISSUER_ID" python3 - <<'PY'
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

# GET-Wrapper. Fehlerhafte Antworten brechen ab, damit `set -e` im Aufrufer greift.
asc_api() {
    curl -fsS -H "Authorization: Bearer $ASC_TOKEN" "$ASC_API$1"
}

# PATCH-Wrapper fuer die wenigen schreibenden Aufrufe (Build ablaufen lassen).
# Body kommt auf stdin. `-f` laesst curl bei 4xx/5xx scheitern; die Fehlermeldung
# von Apple steckt allerdings im Body, den `-f` verwirft — darum `--show-error`
# und im Aufrufer eine eigene Meldung.
asc_api_patch() {
    curl -fsS -X PATCH \
        -H "Authorization: Bearer $ASC_TOKEN" \
        -H "Content-Type: application/json" \
        --data @- \
        "$ASC_API$1"
}
