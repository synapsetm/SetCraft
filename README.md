# SetCraft

Ein DJ-orientierter Musikplayer für macOS (Swift / SwiftUI), mit geplantem
iOS/iPad-Port.

- **Frequenzbasierte RGB-Waveform** (vDSP-FFT, additiv R = Bass, G = Mitten,
  B = Höhen; SwiftUI-Canvas).
- **Tempo-Steuerung** (`AVAudioUnitTimePitch`): pro Track änderbar und global
  als „Master" setzbar; jeder neu geöffnete Track wird auf den Master-Wert
  gezogen. Key-Lock ist immer aktiv — Tempo-Änderungen lassen die Tonart
  unverändert.
- **Editierbare Library** (Inline-TextFields für Titel, Artist, BPM, Genre,
  Album, Label, Comment + klickbare 5-Sterne-Bewertung). Zusätzliche
  Read-only-Spalten für Year, Type, Bitrate und Size. Atomares
  Zurückschreiben via TagLib; Schreibvorgänge auf aktive Player-Dateien
  werden vorgemerkt und beim Entladen nachgeholt.
- **Automatische BPM- und Key-Analyse** (aubio + libKeyFinder) beim Öffnen
  oder per Batch-Button für alle fehlenden Werte. BPM-Oktavkorrektur per
  Genre-Preset (Universal / DnB / Psy-Trance / House / HipHop / Disco)
  inklusive ⅔- und 1½-Faktor für Triolen-Fehldetektion. Re-Analyze und
  manuelle ×2 / ÷2 / ×1.5 / ÷1.5-Korrekturen pro Track im Kontextmenü.
- **Direktes Abspielen** beim Laden eines Tracks (per Drop, Picker,
  Library-Klick); Restzeit-Anzeige neben der gespielten Position
  (`MM:SS / -MM:SS`). **Mausrad/Trackpad-Scrubbing** über der Waveform.
- **Camelot-Key-Färbung** im Player-Chip und in der Library, in den von
  DJ-Apps gewohnten Farben (Position 1–12 als Hue-Wheel, Moll satter, Dur
  heller).
- **Drag & Drop** lädt den Track sofort in den Player und nimmt seinen
  Ordner ggf. als neue Bibliotheks-Quelle auf.
- **Lokalisiert** (Englisch + Deutsch, automatisch nach Systemsprache).
- **Erscheinungsbild** (System / Light / Dark) über das Menü „View",
  Default ist **Dark**. Direkt auf `NSApp.appearance` gesetzt, damit auch
  AppKit-Subviews (List, Table, Canvas) zuverlässig mitwechseln.
- **Auto-Updates** via Sparkle 2.x, signiert mit EdDSA. Menüpunkt
  „SetCraft → Check for Updates…", plus täglicher Hintergrund-Check.
- **Distribution außerhalb des App Stores**: `scripts/release.sh`
  produziert ein Developer-ID-signiertes, notarisiertes, gestapeltes DMG
  inkl. Sparkle-Appcast-Eintrag. Siehe `docs/DISTRIBUTION.md`.
- **About-Panel** mit voller Lizenz- und Copyright-Auflistung der
  eingebundenen Open-Source-Libraries und Verweis aufs Repo (GPL §6).

Privates, nicht-kommerzielles Projekt — GPL-Libraries sind daher zulässig.

> **Planungsdokumente:** `CLAUDE.md` (verbindliche Leitplanken), `SPEC.md`
> (vollständige Spezifikation und Phasenplan), `STATUS.md` (laufendes
> Protokoll).
> UI-Entwurf: `docs/mockup-main.html` im Browser öffnen.

---

## Voraussetzungen

| Werkzeug | Zweck | Installation |
|---|---|---|
| Xcode (App Store) | App-Build, `xcodebuild`, `xcodebuild -create-xcframework` | App Store |
| Command-Line-Tools | git, clang | `xcode-select --install` |
| Homebrew | Build-Tools | https://brew.sh |
| CMake | TagLib + fftw3 + libKeyFinder bauen | `brew install cmake` |
| Python 3.11 | aubio-Build (waf läuft nicht auf 3.12+) | `brew install python@3.11` |

Die C/C++-Libraries werden **nicht** über Homebrew gezogen, sondern aus
Quellen als universelle macOS-`.xcframework`s reproduzierbar gebaut und in
`SetCraftCore/Vendor/` eingecheckt.

---

## Build

### 1) `.xcframework`s erzeugen (einmalig, bei Bedarf neu)

```bash
Vendor/TagLib/build-taglib.sh
Vendor/aubio/build-aubio.sh
Vendor/KeyFinder/build-keyfinder.sh
```

Jedes Skript lädt die Quellen, baut für `arm64 + x86_64` und legt das
`.xcframework` unter `SetCraftCore/Vendor/` ab. Die `Vendor/*/build/`- und
`Vendor/*/src/`-Verzeichnisse sind in `.gitignore`.

Die fertigen `.xcframework`s sind im Repository eingecheckt; die Skripte
muss man nur ausführen, wenn man eine Library aktualisiert.

### 2) App bauen

```bash
xcodebuild -project SetCraft.xcodeproj -scheme SetCraft \
  -destination 'platform=macOS' build
```

Oder Xcode öffnen und „Run" drücken. Der Build erzeugt eine Sandbox-fähige
App mit `readwrite`-Files-Entitlement und Bookmark-Scope (für Phase 5
vorbereitet).

### 3) Tests

```bash
cd SetCraftCore && swift test
```

---

## Architektur (Kurzfassung)

```
┌────────────────────────────────────────────────────┐
│ App-Target SetCraft (SwiftUI, macOS)               │
│  ContentView • PlayerViewModel • LibraryViewModel  │
│  TransportViewModel • WaveformViewModel            │
│  LibraryView • WaveformView • Tempo/KeyChip        │
└──────────────────────┬─────────────────────────────┘
                       │  importiert
┌──────────────────────▼─────────────────────────────┐
│ Swift Package SetCraftCore (plattformfrei)           │
│  Models • AudioEngine • Analyzer • TrackStore      │
│  Waveform • Library • Analysis                     │
└──────────────────────┬─────────────────────────────┘
                       │  Objective-C++ (.mm)
┌──────────────────────▼─────────────────────────────┐
│ SetCraftCoreObjC Target                              │
│  SetCraftTagBridge      → TagLib                     │
│  SetCraftAnalyzerBridge → aubio + libKeyFinder       │
└──────────────────────┬─────────────────────────────┘
                       │  static libs (binaryTarget)
┌──────────────────────▼─────────────────────────────┐
│ SetCraftCore/Vendor/                                 │
│  TagLib.xcframework • aubio.xcframework            │
│  KeyFinder.xcframework (inkl. fftw3)               │
└────────────────────────────────────────────────────┘
```

Die UI hängt **nur** an den Protokollen aus `SetCraftCore`; die C++-Libraries
sind hinter der ObjC++-Bridge gekapselt.

---

## Lizenzen

| Library | Zweck | Lizenz |
|---|---|---|
| AVFoundation, Accelerate, Metal | nativ | Apple |
| aubio | BPM-Analyse | GPLv3 |
| libKeyFinder | Key-Analyse | GPLv3 |
| FFTW | FFT für libKeyFinder | GPLv2+ |
| TagLib | Tag-Lesen/-Schreiben | LGPLv2.1 / MPL |
| utfcpp | UTF-Helfer in TagLib | Boost SL 1.0 |
| GRDB.swift | SQLite-Cache | MIT |
| Sparkle | Auto-Update | MIT |

Da privat / nicht-kommerziell ist GPL hier unproblematisch.
Copyrights und Volltexte sind im About-Panel der App hinterlegt; die
Vendor-Build-Skripte unter `Vendor/` machen die GPLv3-Quellen
reproduzierbar verfügbar (GPL §6).
