#!/usr/bin/env python3
"""Prueft die String-Kataloge gegen die Regeln aus CLAUDE.md.

Gemeldet werden: fehlende de-Eintraege, Platzhalter, die zwischen Key und
Uebersetzung nicht zusammenpassen (Positionsangaben wie %1$@ sind dabei
erwuenscht und werden normalisiert), Eszett statt Doppel-s, Karteileichen,
Keys die im Code stehen aber nicht im Katalog, und Faelle, in denen macOS und
iOS denselben Key unterschiedlich uebersetzen.

Grundlage sind die vom Compiler extrahierten `.stringsdata`. Das Target muss
also vorher gebaut sein — das Skript sucht die Daten selbst, ueber alle
Konfigurationen hinweg, und nimmt je Target den juengsten Stand.

Der Rueckgabewert taugt als Gate: 0 heisst sauber, 1 heisst blockierender
Befund oder fehlende/veraltete Build-Daten. Rein informative Kategorien
(Karteileichen, de == Key bei Einzelbegriffen) lassen ihn unberuehrt.

    python3 scripts/check-localization.py                 # beide Targets
    python3 scripts/check-localization.py --target ios    # nur iOS
"""
import argparse, collections, glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Zwei Orte, weil Xcode Archive-Builds woanders ablegt als normale. Der zweite
# Pfad ist der wichtigere: beide Release-Skripte pruefen zwischen Archive und
# Export, und ohne ihn sah das Gate nie die .stringsdata des Archives, das es
# absichert — sondern Reste des letzten normalen Builds. Genau die veraltete
# Datenlage, die dieses Skript eigentlich melden soll.
DERIVED_GLOBS = [
    os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/SetCraft-*/Build/Intermediates.noindex/SetCraft.build"
    ),
    os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/SetCraft-*/Build/Intermediates.noindex"
        "/ArchiveIntermediates/*/IntermediateBuildFilesPath/SetCraft.build"
    ),
]

# name, Katalog, Xcode-Target-Verzeichnis, Quellordner (fuer die Aktualitaetspruefung)
TARGETS = {
    "macos": ("macOS", "SetCraft/Localizable.xcstrings", "SetCraft.build", "SetCraft"),
    "ios":   ("iOS", "SetCraft iOS/Localizable.xcstrings", "SetCraft iOS.build", "SetCraft iOS"),
}

# Alles andere ist rein informativ und laesst den Rueckgabewert in Ruhe.
BLOCKING = {
    "ohne de-Eintrag (und nicht als unübersetzbar markiert)",
    "state != translated",
    "Platzhalter stimmen nicht überein",
    "ß statt ss",
    "führende/abschliessende Leerzeichen",
    "im Code, nicht im Katalog",
    "macOS und iOS übersetzen denselben Key unterschiedlich",
}


def stringsdata_dir(target_build_dir):
    """Juengstes Objects-normal-Verzeichnis mit .stringsdata fuer dieses Target.

    Ueber alle Konfigurationen hinweg (Debug, Release, -iphonesimulator, …):
    ein Release-Build legt woanders ab als ein Debug-Build, und ein `clean`
    des einen Targets raeumt dem anderen die Daten weg. Deshalb nicht raten,
    sondern nehmen, was zuletzt geschrieben wurde.
    """
    best, best_mtime = None, -1.0
    for derived_glob in DERIVED_GLOBS:
        for base in glob.glob(derived_glob):
            pattern = os.path.join(base, "*", target_build_dir, "Objects-normal", "*", "*.stringsdata")
            for f in glob.glob(pattern):
                m = os.path.getmtime(f)
                if m > best_mtime:
                    best, best_mtime = os.path.dirname(f), m
    return best, best_mtime


def newest_source(folder):
    newest = -1.0
    for dirpath, _, files in os.walk(os.path.join(ROOT, folder)):
        for f in files:
            if f.endswith(".swift"):
                newest = max(newest, os.path.getmtime(os.path.join(dirpath, f)))
    return newest


def extracted(base):
    keys = set()
    for f in glob.glob(base + "/*.stringsdata"):
        with open(f) as fh:
            d = json.load(fh)
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


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", choices=["macos", "ios", "both"], default="both",
                    help="Welche Kataloge geprueft werden (Default: both).")
    args = ap.parse_args()
    wanted = ["macos", "ios"] if args.target == "both" else [args.target]

    all_de = {}
    problems = collections.defaultdict(list)
    fatal = []

    for key_name in wanted:
        name, catalog, build_dir, src_dir = TARGETS[key_name]
        base, data_mtime = stringsdata_dir(build_dir)
        if base is None:
            fatal.append(
                f"{name}: keine .stringsdata gefunden — Target zuerst bauen "
                f"(ohne Build laesst sich nichts pruefen)."
            )
            continue
        if data_mtime < newest_source(src_dir):
            fatal.append(
                f"{name}: .stringsdata ist aelter als die Quellen in '{src_dir}/' — "
                f"Target neu bauen, sonst prueft das Skript einen veralteten Stand."
            )
            continue

        with open(os.path.join(ROOT, catalog)) as fh:
            cat = json.load(fh)["strings"]
        code = extracted(base)

        for key, entry in cat.items():
            loc = entry.get("localizations", {}).get("de", {}).get("stringUnit", {})
            de = loc.get("value")
            state = loc.get("state")
            if de is None:
                if entry.get("shouldTranslate") is not False:
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

    # Nur sinnvoll, wenn beide Kataloge im selben Lauf gelesen wurden.
    if len(wanted) == 2:
        for key, by_target in all_de.items():
            if len(by_target) == 2 and by_target["macOS"] != by_target["iOS"]:
                problems["macOS und iOS übersetzen denselben Key unterschiedlich"].append(
                    f"{key!r}\n      macOS: {by_target['macOS']!r}\n      iOS:   {by_target['iOS']!r}")

    for line in fatal:
        print(f"\n### Nicht pruefbar\n    {line}")

    for kind, items in problems.items():
        marker = "BLOCKIEREND" if kind in BLOCKING else "Hinweis"
        print(f"\n### [{marker}] {kind} ({len(items)})")
        for i in items:
            print("   ", i)

    blocking = sorted(k for k in problems if k in BLOCKING)
    if not fatal and not blocking:
        print("Keine blockierenden Auffälligkeiten.")
        return 0
    if blocking:
        print(f"\nBlockierend: {', '.join(blocking)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
