# Setify

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
  Genre-Preset (Universal / DnB / House / HipHop / Disco).
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
  „Setify → Check for Updates…", plus täglicher Hintergrund-Check.
- **Distribution außerhalb des App Stores**: `scripts/release.sh`
  produziert ein Developer-ID-signiertes, notarisiertes, gestapeltes DMG
  inkl. Sparkle-Appcast-Eintrag. Siehe `docs/DISTRIBUTION.md`.

Privates, nicht-kommerzielles Projekt — GPL-Libraries sind daher zulässig.

> **Planungsdokumente:** `CLAUDE.md` (verbindliche Leitplanken), `SPEC.md`
> (vollständige Spezifikation und Phasenplan), `STATUS.md` (laufendes
> Protokoll).
> UI-Entwurf: `docs/mockup-main.html` im Browser öffnen.

---

## Stand

Phasen **0 – 5a** sind durchgespielt, plus zwei zusätzliche Runden:
UI-Politur und Lokalisierung („Sitzung 2026-06-01") und Distribution-
Inbetriebnahme + Waveform-Prefetch + Dark als Default
(„Sitzung 2026-06-02" in `STATUS.md`). Tests: `swift test` im
`SetifyCore`-Paket — aktuell **36 grün**.

Die Verteilung außerhalb des App Stores ist **einsatzbereit**:
Developer-ID-Cert, Notarytool-Profil, Sparkle-Keys und GitHub-Pages-
Hosting sind eingerichtet. Pro Release reicht
`./scripts/release.sh` — Build, Notarisierung, GitHub-Release-Upload
und Appcast-Push laufen automatisch. Details in `docs/DISTRIBUTION.md`.

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
`SetifyCore/Vendor/` eingecheckt.

---

## Build

### 1) `.xcframework`s erzeugen (einmalig, bei Bedarf neu)

```bash
Vendor/TagLib/build-taglib.sh
Vendor/aubio/build-aubio.sh
Vendor/KeyFinder/build-keyfinder.sh
```

Jedes Skript lädt die Quellen, baut für `arm64 + x86_64` und legt das
`.xcframework` unter `SetifyCore/Vendor/` ab. Die `Vendor/*/build/`- und
`Vendor/*/src/`-Verzeichnisse sind in `.gitignore`.

Die fertigen `.xcframework`s sind im Repository eingecheckt; die Skripte
muss man nur ausführen, wenn man eine Library aktualisiert.

### 2) App bauen

```bash
xcodebuild -project Setify.xcodeproj -scheme Setify \
  -destination 'platform=macOS' build
```

Oder Xcode öffnen und „Run" drücken. Der Build erzeugt eine Sandbox-fähige
App mit `readwrite`-Files-Entitlement und Bookmark-Scope (für Phase 5
vorbereitet).

### 3) Tests

```bash
cd SetifyCore && swift test
```

---

## Architektur (Kurzfassung)

```
┌────────────────────────────────────────────────────┐
│ App-Target Setify (SwiftUI, macOS)                 │
│  ContentView • PlayerViewModel • LibraryViewModel  │
│  TransportViewModel • WaveformViewModel            │
│  LibraryView • WaveformView • Tempo/KeyChip        │
└──────────────────────┬─────────────────────────────┘
                       │  importiert
┌──────────────────────▼─────────────────────────────┐
│ Swift Package SetifyCore (plattformfrei)           │
│  Models • AudioEngine • Analyzer • TrackStore      │
│  Waveform • Library • Analysis                     │
└──────────────────────┬─────────────────────────────┘
                       │  Objective-C++ (.mm)
┌──────────────────────▼─────────────────────────────┐
│ SetifyCoreObjC Target                              │
│  SetifyTagBridge      → TagLib                     │
│  SetifyAnalyzerBridge → aubio + libKeyFinder       │
└──────────────────────┬─────────────────────────────┘
                       │  static libs (binaryTarget)
┌──────────────────────▼─────────────────────────────┐
│ SetifyCore/Vendor/                                 │
│  TagLib.xcframework • aubio.xcframework            │
│  KeyFinder.xcframework (inkl. fftw3)               │
└────────────────────────────────────────────────────┘
```

Die UI hängt **nur** an den Protokollen aus `SetifyCore`; die C++-Libraries
sind hinter der ObjC++-Bridge gekapselt.

---

## Lizenzen

| Library | Zweck | Lizenz |
|---|---|---|
| AVFoundation, Accelerate, Metal | nativ | Apple |
| aubio | BPM-Analyse | GPL |
| libKeyFinder | Key-Analyse | GPL |
| TagLib | Tag-Lesen/-Schreiben | LGPL |
| fftw3 | FFT für libKeyFinder | BSD |
| GRDB.swift *(Phase 5)* | SQLite-Cache | MIT |
| SFBAudioEngine *(optional, Phase 5)* | zusätzliche Decoder | MIT/BSD-Anteile |

Da privat / nicht-kommerziell ist GPL hier unproblematisch.
