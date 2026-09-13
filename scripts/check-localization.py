#!/usr/bin/env python3
"""Prueft beide String-Kataloge gegen die Regeln aus CLAUDE.md.

Gemeldet werden: fehlende de-Eintraege, Platzhalter, die zwischen Key und
Uebersetzung nicht zusammenpassen (Positionsangaben wie %1$@ sind dabei
erwuenscht und werden normalisiert), Eszett statt Doppel-s, Karteileichen, Keys die
im Code stehen aber nicht im Katalog, und Faelle, in denen macOS und iOS
denselben Key unterschiedlich uebersetzen.

Grundlage sind die vom Compiler extrahierten `.stringsdata` — beide Targets
muessen also vorher gebaut sein. Nach einem `clean` eines Targets sind die
Daten des anderen weg; dann meldet das Skript reihenweise Karteileichen.

    python3 scripts/check-localization.py
"""
import json, glob, re, sys, collections

DERIVED = "/Users/beatbuehler/Library/Developer/Xcode/DerivedData/SetCraft-fehyclbsmkhnjydjnovlebenftxn/Build/Intermediates.noindex/SetCraft.build"
TARGETS = [
    ("macOS", "SetCraft/Localizable.xcstrings", DERIVED + "/Debug/SetCraft.build/Objects-normal/arm64"),
    ("iOS",   "SetCraft iOS/Localizable.xcstrings", DERIVED + "/Debug-iphonesimulator/SetCraft iOS.build/Objects-normal/arm64"),
]
SPEC = re.compile(r'%(?:\d+\$)?[@a-zA-Z]*(?:lld|lf|ld|d|@|f|s)')

def extracted(base):
    keys = set()
    for f in glob.glob(base + "/*.stringsdata"):
        d = json.load(open(f))
        for _, entries in d.get("tables", {}).items():
            for e in entries:
                if isinstance(e, dict) and "key" in e:
                    keys.add(e["key"])
    return keys

def specs(text):
    # Positionsangaben (%1$@) sind laut CLAUDE.md erwuenscht — verglichen wird
    # nur, welche Typen wie oft vorkommen.
    return collections.Counter(
        m.group(1) for m in re.finditer(r'%(?:\d+\$)?(lld|lf|ld|d|@|f)', text)
    )

all_de = {}
problems = collections.defaultdict(list)

for name, path, base in TARGETS:
    cat = json.load(open(path))["strings"]
    code = extracted(base)

    for key, entry in cat.items():
        loc = entry.get("localizations", {}).get("de", {}).get("stringUnit", {})
        de = loc.get("value")
        state = loc.get("state")
        if de is None:
            if not entry.get("shouldTranslate") is False:
                problems["ohne de-Eintrag (und nicht als unübersetzbar markiert)"].append(f"{name}: {key!r}")
            continue
        all_de.setdefault(key, {})[name] = de
        if state != "translated":
            problems["state != translated"].append(f"{name}: {key!r} -> {state}")
        if specs(key) != specs(de):
            problems["Platzhalter stimmen nicht überein"].append(f"{name}: {key!r} -> {de!r}")
        if "ß" in de:
            problems["ß statt ss"].append(f"{name}: {de!r}")
        if de == key and len(key) > 3 and not re.fullmatch(r'[\W\d%@l\s]+', key):
            problems["de identisch zum englischen Key"].append(f"{name}: {key!r}")
        if de.strip() != de:
            problems["führende/abschliessende Leerzeichen"].append(f"{name}: {de!r}")

    for key in sorted(code - set(cat)):
        problems["im Code, nicht im Katalog"].append(f"{name}: {key!r}")
    for key in sorted(set(cat) - code):
        problems["Karteileiche (nicht mehr im Code)"].append(f"{name}: {key!r}")

for key, byTarget in all_de.items():
    if len(byTarget) == 2 and byTarget["macOS"] != byTarget["iOS"]:
        problems["macOS und iOS übersetzen denselben Key unterschiedlich"].append(
            f"{key!r}\n      macOS: {byTarget['macOS']!r}\n      iOS:   {byTarget['iOS']!r}")

if not problems:
    print("Keine Auffälligkeiten.")
for kind, items in problems.items():
    print(f"\n### {kind} ({len(items)})")
    for i in items:
        print("   ", i)
