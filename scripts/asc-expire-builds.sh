#!/usr/bin/env bash
#
# asc-expire-builds.sh — laesst alle TestFlight-Builds ausser dem neuesten
# ablaufen, damit auf dem Geraet nur noch der aktuelle Stand installierbar ist.
#
# Apple macht das nicht zuverlaessig von selbst: am 2026-09-20 standen Build 21
# und Build 19 gleichzeitig aktiv, waehrend 20 und 18 abgelaufen waren. Wer dann
# in TestFlight auf „Installieren" tippt, testet womoeglich den falschen Stand —
# und meldet Fehler, die laengst behoben sind.
#
# SICHERHEITSREGEL: behalten wird immer der neueste Build mit
# processingState == VALID. Ist der neueste Build noch in Verarbeitung, bricht
# das Skript ab, statt die aelteren wegzuraeumen — sonst bleibt fuer die Dauer
# der Verarbeitung nichts Installierbares uebrig.
#
# Usage:
#   scripts/asc-expire-builds.sh              # abgelaufen setzen
#   scripts/asc-expire-builds.sh --dry-run    # nur zeigen, was passieren wuerde
#   scripts/asc-expire-builds.sh -b <bundle>  # andere Bundle-ID

set -euo pipefail

readonly BUNDLE_ID_DEFAULT="ch.buehler.beat.SetCraft.iOS"

bundle_id="$BUNDLE_ID_DEFAULT"
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        -b) bundle_id="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
        *) printf 'Unbekannte Option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

log()  { printf '\n\033[1;34m> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/asc-auth.sh
source "$(dirname "${BASH_SOURCE[0]}")/asc-auth.sh"

log "App suchen: $bundle_id"
app_json="$(asc_api "/v1/apps?filter%5BbundleId%5D=$bundle_id")" || fail "App-Abfrage fehlgeschlagen."
app_id="$(jq -r '.data[0].id // empty' <<<"$app_json")"
[ -n "$app_id" ] || fail "Keine App mit Bundle-ID $bundle_id gefunden."
jq -r '.data[0] | "   \(.attributes.name)  (id \(.id))"' <<<"$app_json"

# `sort=-version` sortiert Apple lexikografisch; fuer zweistellige Build-Nummern
# reicht das nicht („9" > „22"). Darum numerisch nachsortieren.
builds_json="$(asc_api "/v1/builds?filter%5Bapp%5D=$app_id&limit=50&fields%5Bbuilds%5D=version,processingState,expired,uploadedDate")" \
    || fail "Build-Abfrage fehlgeschlagen."

newest_valid_version="$(jq -r '
    [.data[] | select(.attributes.processingState == "VALID")]
    | sort_by(.attributes.version | tonumber) | last | .attributes.version // empty
' <<<"$builds_json")"

newest_version="$(jq -r '
    [.data[]] | sort_by(.attributes.version | tonumber) | last | .attributes.version // empty
' <<<"$builds_json")"

[ -n "$newest_valid_version" ] || fail "Kein Build im Zustand VALID — nichts zu tun."

if [ "$newest_version" != "$newest_valid_version" ]; then
    newest_state="$(jq -r --arg v "$newest_version" '
        .data[] | select(.attributes.version == $v) | .attributes.processingState
    ' <<<"$builds_json")"
    fail "Build $newest_version ist noch $newest_state. Erst abwarten (scripts/asc-status.sh) — sonst bliebe waehrend der Verarbeitung nichts Installierbares."
fi

log "Behalten: Build $newest_valid_version (VALID)"

# Kandidaten: alles ausser dem neuesten VALID, was noch nicht abgelaufen ist.
# Kein `mapfile` — die Bash auf macOS ist 3.2 und kennt es nicht.
doomed=()
while IFS= read -r row; do
    [ -n "$row" ] && doomed+=("$row")
done < <(jq -r --arg keep "$newest_valid_version" '
    .data[]
    | select(.attributes.version != $keep and .attributes.expired == false)
    | "\(.id)\t\(.attributes.version)"
' <<<"$builds_json" | sort -k2 -n)

if [ "${#doomed[@]}" -eq 0 ]; then
    log "Nichts zu tun — alle aelteren Builds sind bereits abgelaufen."
    exit 0
fi

log "Ablaufen lassen (${#doomed[@]}):"
for row in "${doomed[@]}"; do
    printf '   Build %s\n' "$(cut -f2 <<<"$row")"
done

if [ "$dry_run" -eq 1 ]; then
    log "--dry-run: nichts geaendert."
    exit 0
fi

for row in "${doomed[@]}"; do
    id="$(cut -f1 <<<"$row")"
    version="$(cut -f2 <<<"$row")"
    body="$(jq -nc --arg id "$id" '{data: {type: "builds", id: $id, attributes: {expired: true}}}')"
    if printf '%s' "$body" | asc_api_patch "/v1/builds/$id" >/dev/null; then
        printf '   \033[1;32mBuild %s abgelaufen\033[0m\n' "$version"
    else
        fail "Build $version liess sich nicht ablaufen lassen."
    fi
done

log "Fertig — installierbar bleibt nur Build $newest_valid_version."
