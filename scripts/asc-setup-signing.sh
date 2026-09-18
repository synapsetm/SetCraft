#!/usr/bin/env bash
#
# asc-setup-signing.sh — richtet die Distribution-Signatur fuer iOS ein:
# "Apple Distribution"-Zertifikat im Schluesselbund plus ein App-Store-
# Provisioning-Profil, das genau dieses Zertifikat enthaelt.
#
# Warum: ohne lokale Distribution-Identitaet weicht `xcodebuild -exportArchive`
# auf Cloud-Signing aus und scheitert dort an der Rolle des ASC-API-Keys
# ("You haven't been given access to cloud-managed distribution certificates").
# Mit Zertifikat UND passendem Profil kann der Export manuell signieren und
# fragt das Cloud-Signing gar nicht erst — release-ios.sh laeuft dann in einem
# Rutsch bis zum Upload durch, ohne Umweg ueber den Xcode Organizer.
#
# Idempotent: was schon existiert, wird uebersprungen. Einmal einrichten,
# danach nur noch bei Ablauf (Zertifikat ein Jahr, Profil ein Jahr) erneut.
#
# Usage:
#   scripts/asc-setup-signing.sh          # einrichten bzw. vervollstaendigen
#   scripts/asc-setup-signing.sh --list   # nur den Ist-Zustand zeigen

set -euo pipefail

readonly CERT_DIR="$HOME/.appstoreconnect/certificates"
readonly PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
readonly CERT_TYPE="DISTRIBUTION"          # = "Apple Distribution" (iOS + macOS)
readonly PROFILE_TYPE="IOS_APP_STORE"
readonly PROFILE_NAME="SetCraft iOS App Store"
readonly BUNDLE_ID="ch.buehler.beat.SetCraft.iOS"

log()  { printf '\n\033[1;34m> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/asc-auth.sh
source "$(dirname "${BASH_SOURCE[0]}")/asc-auth.sh"

show_state() {
    log "Zertifikate im Account"
    asc_api "/v1/certificates?limit=200" \
        | jq -r '.data[] | "   \(.attributes.certificateType)  \(.attributes.name)  laeuft ab \(.attributes.expirationDate[:10])"'
    log "Profile im Account"
    asc_api "/v1/profiles?limit=200" \
        | jq -r 'if (.data|length) == 0 then "   (keine)" else (.data[] | "   \(.attributes.profileType)  \(.attributes.name)  [\(.attributes.profileState)]") end'
    log "Lokale Signing-Identitaeten"
    security find-identity -v -p codesigning || true
}

if [ "${1:-}" = "--list" ]; then
    show_state
    exit 0
fi

# ---------- 1) Zertifikat ---------------------------------------------------

log "Distribution-Zertifikat pruefen"
certs="$(asc_api "/v1/certificates?limit=200")" || fail "Abfrage fehlgeschlagen."
cert_id="$(jq -r --arg t "$CERT_TYPE" 'first(.data[] | select(.attributes.certificateType == $t) | .id) // empty' <<<"$certs")"

if [ -n "$cert_id" ]; then
    echo "   vorhanden (id $cert_id) — Anlegen uebersprungen."
    security find-identity -v -p codesigning | grep -q "Apple Distribution" \
        || warn "   ACHTUNG: im Schluesselbund fehlt die passende Identitaet. Ohne den
   privaten Schluessel ist das Zertifikat hier wertlos — im Developer-Portal
   widerrufen und dieses Skript erneut laufen lassen."
else
    mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
    stamp="$(date +%Y%m%d)"
    key_file="$CERT_DIR/apple-distribution-$stamp.key"
    csr_file="$CERT_DIR/apple-distribution-$stamp.csr"
    cer_file="$CERT_DIR/apple-distribution-$stamp.cer"
    p12_file="$CERT_DIR/apple-distribution-$stamp.p12"
    [ -f "$key_file" ] && fail "Es gibt schon einen Schluessel von heute: $key_file"

    echo "   Privaten Schluessel + CSR erzeugen (RSA 2048, das akzeptiert Apple)."
    openssl genrsa -out "$key_file" 2048 2>/dev/null
    chmod 600 "$key_file"
    # Der Subject-Inhalt ist Apple weitgehend egal — den Namen vergibt der
    # Account. Ein gueltiger CSR muss es trotzdem sein.
    openssl req -new -key "$key_file" -out "$csr_file" \
        -subj "/CN=Apple Distribution/O=Beat Buehler/C=CH" 2>/dev/null

    echo "   Zertifikat bei App Store Connect anfordern."
    response="$(jq -n --arg csr "$(cat "$csr_file")" --arg type "$CERT_TYPE" \
        '{data: {type: "certificates", attributes: {csrContent: $csr, certificateType: $type}}}' \
        | curl -sS -X POST "$ASC_API/v1/certificates" \
            -H "Authorization: Bearer $ASC_TOKEN" -H "Content-Type: application/json" -d @-)"
    jq -e '.data.id' >/dev/null 2>&1 <<<"$response" || {
        jq -r '.errors[]? | "   \(.title)\n   \(.detail)"' <<<"$response" 2>/dev/null || echo "$response"
        fail "Anlegen fehlgeschlagen — bleibt der Rollen-Weg (Key auf Admin/App Manager)."
    }
    cert_id="$(jq -r '.data.id' <<<"$response")"
    jq -r '.data.attributes.certificateContent' <<<"$response" | base64 -d > "$cer_file"
    echo "   $(jq -r '.data.attributes.name' <<<"$response") — laeuft ab $(jq -r '.data.attributes.expirationDate[:10]' <<<"$response")"

    echo "   Als PKCS#12 buendeln und in den Login-Schluesselbund importieren."
    openssl x509 -inform DER -in "$cer_file" -out "$cer_file.pem" 2>/dev/null
    p12_pass="$(openssl rand -base64 18)"
    openssl pkcs12 -export -legacy -inkey "$key_file" -in "$cer_file.pem" \
        -name "Apple Distribution" -out "$p12_file" -passout "pass:$p12_pass" 2>/dev/null
    chmod 600 "$p12_file"
    # -T gibt codesign und den Build-Tools Zugriff. Beim ersten Signieren fragt
    # der Schluesselbund trotzdem einmal nach — das ist der Moment fuer
    # "Immer erlauben".
    security import "$p12_file" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$p12_pass" -T /usr/bin/codesign -T /usr/bin/security \
        -T /usr/bin/xcodebuild -T /usr/bin/productbuild
fi

# ---------- 2) Provisioning-Profil ------------------------------------------

log "App-Store-Profil pruefen"
profiles="$(asc_api "/v1/profiles?limit=200")" || fail "Abfrage fehlgeschlagen."
profile_id="$(jq -r --arg n "$PROFILE_NAME" 'first(.data[] | select(.attributes.name == $n) | .id) // empty' <<<"$profiles")"

if [ -n "$profile_id" ]; then
    echo "   „$PROFILE_NAME\" existiert (id $profile_id) — Anlegen uebersprungen."
    profile_response="$(asc_api "/v1/profiles/$profile_id")"
else
    bundle_uid="$(asc_api "/v1/bundleIds?limit=200" \
        | jq -r --arg b "$BUNDLE_ID" 'first(.data[] | select(.attributes.identifier == $b) | .id) // empty')"
    [ -n "$bundle_uid" ] || fail "Bundle-ID $BUNDLE_ID ist im Account nicht registriert."
    echo "   Anlegen fuer $BUNDLE_ID (id $bundle_uid), gebunden an Zertifikat $cert_id."
    profile_response="$(jq -n \
        --arg name "$PROFILE_NAME" --arg type "$PROFILE_TYPE" \
        --arg bundle "$bundle_uid" --arg cert "$cert_id" \
        '{data: {type: "profiles",
                 attributes: {name: $name, profileType: $type},
                 relationships: {bundleId: {data: {type: "bundleIds", id: $bundle}},
                                 certificates: {data: [{type: "certificates", id: $cert}]}}}}' \
        | curl -sS -X POST "$ASC_API/v1/profiles" \
            -H "Authorization: Bearer $ASC_TOKEN" -H "Content-Type: application/json" -d @-)"
    jq -e '.data.id' >/dev/null 2>&1 <<<"$profile_response" || {
        jq -r '.errors[]? | "   \(.title)\n   \(.detail)"' <<<"$profile_response" 2>/dev/null || echo "$profile_response"
        fail "Profil anlegen fehlgeschlagen."
    }
    echo "   laeuft ab $(jq -r '.data.attributes.expirationDate[:10]' <<<"$profile_response")"
fi

# ---------- 3) Profil lokal installieren ------------------------------------

log "Profil lokal ablegen"
mkdir -p "$PROFILE_DIR"
tmp_profile="$(mktemp -t setcraft-profile)"
jq -r '.data.attributes.profileContent' <<<"$profile_response" | base64 -d > "$tmp_profile"
# Die .mobileprovision ist CMS-signiert; die UUID steht im eingebetteten Plist
# und ist zugleich der Dateiname, unter dem Xcode das Profil erwartet.
# PlistBuddy braucht dafuer eine echte Datei — /dev/stdin kann es nicht lesen.
tmp_plist="$(mktemp -t setcraft-profile-plist)"
security cms -D -i "$tmp_profile" > "$tmp_plist" 2>/dev/null
uuid="$(/usr/libexec/PlistBuddy -c "Print :UUID" "$tmp_plist")"
rm -f "$tmp_plist"
[ -n "$uuid" ] || fail "UUID aus dem Profil nicht lesbar."
mv "$tmp_profile" "$PROFILE_DIR/$uuid.mobileprovision"
echo "   $PROFILE_DIR/$uuid.mobileprovision"

show_state

cat <<NOTE

   Schluessel und Zertifikat liegen unter $CERT_DIR (chmod 600).
   Sichere den Ordner mit — ohne den privaten Schluessel ist das Zertifikat
   auf einem neuen Rechner wertlos. Er gehoert NICHT ins Repo.

   ExportOptions-iOS.plist signiert manuell gegen „$PROFILE_NAME".
   Naechster Schritt: ./scripts/release-ios.sh laeuft jetzt bis zum Upload
   durch, ohne Organizer.
NOTE
