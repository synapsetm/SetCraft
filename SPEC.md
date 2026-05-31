# SPEC.md — Vollständige Projektspezifikation (Setify)

> Begleitdokument zu `CLAUDE.md`. Hier stehen die Details und Begründungen.
> Bei Konflikten gewinnt `CLAUDE.md` für die harten Regeln; dieses Dokument liefert den Kontext.

---

## 1. Ziel & Rahmen

Ein DJ-orientierter Musikplayer („Setify") für **macOS** (zuerst), mit vorbereitetem **iOS/iPad**-Port.
Es geht **nicht** um eine Mixing-Software mit zwei Decks, sondern um einen **Player + Bibliotheks-/Vorbereitungstool**:
Tracks sichten, analysieren, bewerten, Tempo/Key prüfen und anpassen, Metadaten pflegen.

**Lizenzrahmen:** privates, nicht-kommerzielles Projekt. GPL ist daher unproblematisch.
Falls das Projekt je kommerziell werden soll, sind die GPL-Bausteine (aubio, libKeyFinder) die Blocker —
deshalb sind sie hinter Protokollen gekapselt und austauschbar (siehe Architektur).

**Aktueller Stand:** Das Xcode-Projekt existiert bereits in der schlanken Default-Struktur (siehe §6).

---

## 2. Tech-Stack mit Begründung

### Audio laden / dekodieren — AVFoundation
`AVAudioFile` / `AVAudioPCMBuffer`. Deckt nativ ab: MP3, AAC/M4A, ALAC, WAV, AIFF, CAF und
(auf aktuellen OS-Versionen) FLAC und Opus.
- **Nicht nativ:** Ogg Vorbis. Außerdem ist die native FLAC-Dekodierung über die AudioFile-API langsam
  (die Datei wird beim ersten Lesen komplett durchgescannt).
- **Fallback bei Bedarf:** `SFBAudioEngine` (eigene Decoder für Ogg Vorbis, WavPack, Monkey's Audio u. a.
  sowie schnellere FLAC-Dekodierung). Erst einziehen, wenn die echte Sammlung es nötig macht.

### Abspielen + Tempo/Key — AVAudioEngine + AVAudioUnitTimePitch
Ein einziger `AVAudioUnitTimePitch`-Knoten deckt **beide** Funktionen ab:
- `rate` → Tempo (entkoppelt von der Tonhöhe = Key-Lock).
- `pitch` → Tonhöhe in **Cents** (100 Cents = 1 Halbton).
„Key ändern, Tempo lassen" = `rate = 1.0`, nur `pitch` drehen.
„Tempo ändern, Key lassen" = nur `rate` drehen.
Nativ, lizenzfrei, kein C++-Bridging.
- **Optionales Qualitäts-Upgrade später:** Rubber Band (GPL, hier ok) oder Signalsmith Stretch (MIT)
  als Ersatz für den Time-Pitch-Knoten — nur austauschen, wenn die native Qualität nicht reicht.

### BPM-Analyse — aubio (GPL, C)
Standard für Beat-/Tempo-Tracking. **DnB-Warnung:** Oktavfehler (174 → 87). Korrektur einplanen
(erwarteter Bereich z. B. 140–180 oder Verdopplungs-Heuristik).

### Key-Analyse — libKeyFinder (GPL, C++)
Vom Mixxx-Team gepflegt, qualitativ das Beste im Open-Source-Bereich. Ergebnis auf Camelot mappen.

### Waveform — Accelerate/vDSP (Analyse) + Metal (Rendering)
Keine fertige Library für die frequenzbasierte RGB-Waveform — das ist der selbst gebaute Teil.
- vDSP: FFT pro Zeitfenster, Energie in 3 Bändern.
- Mapping: **Low (< ~200 Hz) → Rot, Mid (~200 Hz–2 kHz) → Grün, High (> ~2 kHz) → Blau**, additiv kombiniert.
  Bass+Mitte ergibt Orange, Bass+Höhen ergibt Violett (wie im Mockup).
- Balkenhöhe = Gesamtamplitude des Fensters, Balkenfarbe = RGB-Ergebnis.
- Rendering mit Metal; für einen ersten Durchstich genügt SwiftUI `Canvas` mit vorberechneten Daten.
- Referenz für Frequenzgrenzen/Normalisierung: Mixxx (GPL, offen einsehbar).

### Tags — TagLib (LGPL, C++)
Einheitliche API über Vorbis Comments (FLAC), MP4-Atoms (ALAC/M4A) und ID3 (MP3/AIFF).
Das Rating-Mapping (siehe unten) bauen wir selbst obendrauf.

### Bibliothek-Speicher — Mittelweg
`TrackStore`-Protokoll. **Phase 1 Implementierung: Tags-only** (TagLib direkt, Datei = Quelle der Wahrheit).
Später optional eine zweite Implementierung mit **SQLite-Cache (GRDB.swift, MIT)** für Geschwindigkeit,
Suche, Crates/Playlists, Verlauf — ohne dass UI/Engine etwas merken.

---

## 3. Architektur

```
┌─────────────────────────────────────────────┐
│ UI (SwiftUI, macOS — später iOS-Target)      │
│  Views + ViewModels                          │
└───────────────┬─────────────────────────────┘
                │ nur über Protokolle
┌───────────────▼─────────────────────────────┐
│ Core-Logik (plattformfrei)                   │
│  • Models (Track, Rating, CamelotKey, …)     │
│  • AudioEngine   (Protokoll)                 │
│  • Analyzer      (Protokoll: BPM + Key)      │
│  • TrackStore    (Protokoll: laden/schreiben)│
│  • Waveform-DSP  (vDSP, 3-Band → RGB)        │
└───────────────┬─────────────────────────────┘
                │ Objective-C++ (.mm) Brücke
┌───────────────▼─────────────────────────────┐
│ Bridge                                       │
│  aubio · libKeyFinder · TagLib               │
│  (C/C++ — komplett gekapselt)                │
└──────────────────────────────────────────────┘
```

Ob die Core-Logik ein eigenes Swift Package `SetifyCore` wird oder eine Ordnergruppe im bestehenden
Projekt bleibt, entscheiden wir in Phase 0 (siehe §6). Die **Trennung UI ↔ Logik ↔ Bridge** gilt in
beiden Fällen.

**Protokolle als Schnittstellen (Beispiel-Signaturen, von Claude Code zu verfeinern):**

```swift
protocol AudioEngine {
    func load(url: URL) throws
    func play(); func pause(); func seek(to seconds: Double)
    var rate: Double { get set }          // Tempo
    var pitchCents: Double { get set }     // Key (Cents)
    var keyLock: Bool { get set }
}

protocol Analyzer {
    func analyzeBPM(url: URL) async throws -> Double
    func analyzeKey(url: URL) async throws -> CamelotKey
}

protocol TrackStore {
    func loadLibrary(folder: URL) async throws -> [Track]
    func updateRating(_ track: Track, stars: Int) async throws
    func updateBPM(_ track: Track, bpm: Double) async throws
    func updateKey(_ track: Track, key: CamelotKey) async throws
    func updateText(_ track: Track, field: EditableField, value: String) async throws
}
```

Die GPL-Implementierungen (`AubioAnalyzer`, `KeyFinderAnalyzer`) und die TagLib-Implementierung
(`TagLibTrackStore`) liegen hinter diesen Protokollen.

---

## 4. Tag-Strategie im Detail

Priorität: **Serato DJ** und **Rekordbox** (beide vom Nutzer verwendet).

### Felder pro Wert

| Wert | ID3 (MP3/AIFF) | Vorbis (FLAC) | MP4 (M4A/ALAC) |
|---|---|---|---|
| BPM | `TBPM` | `BPM` | `tmpo` |
| Key (Camelot) | `TKEY` + `INITIALKEY` | `INITIALKEY` | Freeform-Atom |
| Rating | `POPM` (WMP-Mapping) | `RATING` (+ `FMPS_RATING`) | Freeform-Atom |
| Rating (sichtbar) | `COMM` (Sterne-Präfix) | `COMMENT` (Sterne-Präfix) | `©cmt` (Sterne-Präfix) |

### Warum Rating doppelt?
- `POPM`/`RATING` ist das „richtige" Feld, wird aber von Rekordbox **nicht gelesen** (Rekordbox hält
  Ratings in seiner DB) und von Serato nur uneinheitlich.
- Das **Kommentarfeld** wird von Serato **und** Rekordbox angezeigt → dort ein Sterne-Präfix als
  garantiert sichtbarer gemeinsamer Nenner. (Gleiches Prinzip wie Mixed In Key.)

### POPM-Mapping (WMP/Windows-Konvention)
| Sterne | Schreibwert | Lese-Bereich |
|---|---|---|
| 5 | 255 | 224–255 |
| 4 | 196 | 160–223 |
| 3 | 128 | 96–159 |
| 2 | 64 | 32–95 |
| 1 | 1 | 1–31 |
| 0 | (Feld entfernen) | 0 |

### Kommentar-Präfix
- Format-Vorschlag: `★★★★☆ | <restlicher Kommentar>` (menschenlesbar) **oder** maschinenfreundliches
  Token `[R4]` am Anfang. Eine Variante festlegen und konsistent lesen/schreiben.
- **Bestehenden Kommentartext zwingend erhalten:** nur das Präfix/Token ersetzen, Rest beibehalten.
- Beim Lesen Token herausparsen und vom angezeigten Kommentar trennen.

### Schreib-Sicherheit (Pflicht)
- **Atomar**: temporäre Datei schreiben, dann atomar umbenennen.
- **Nicht in den aktiven Track schreiben**; Schreibzugriffe serialisieren (eine Schreib-Queue).
- Scan & Analyse **asynchron**, UI nie blockieren.
- **Rekordbox** muss Tags manuell neu laden („reload tags") — im UI/Doku erwähnen.

---

## 5. UI-Spezifikation (letzter Mockup-Stand: kompakte Chip-Variante)

Referenz-Datei: `docs/mockup-main.html` (im Browser öffnen).
Dunkles Theme, Akzentfarbe Orange (`#FF8A3D`), Key-Akzent Grün (`#5DCAA5`).

**Aufbau von oben nach unten:**

1. **Kopfzeile**: Cover-Platzhalter, Titel + Artist, Cue-Button, Play/Pause-Button, Laufzeit `1:47 / 5:12`.
2. **RGB-Waveform**: frequenzbasiert eingefärbt; **Cue-Marker** (unten) und **Playhead** (vertikale Linie),
   abgespielter Bereich abgedunkelt. Klick auf die Waveform = Seek.
3. **Kompakte Steuer-Chips** direkt über der Track-Liste:
   - **Tempo-Chip** zeigt aktuelle BPM + „global"-Label. Klick öffnet Popover mit:
     BPM-Zahlenfeld, Fein-`%`-Regler, **„global"-Schalter**.
   - **Key-Chip** zeigt aktuellen Camelot-Key + „global"-Label. Klick öffnet Popover mit:
     Camelot-Auswahl, **Halbton-Nudge (− / +)**, **„global"-Schalter**.
   - **„global" an** = Wert gilt als Master für **jeden** geöffneten Track; **aus** = nur dieser Track.
   - **Key-Lock-Indikator** rechts.
4. **Track-Bibliothek (Tabelle)**, Spalten:
   - Play-Indikator / Laufnummer
   - **Titel** (inline editierbar)
   - **Artist** (inline editierbar)
   - **BPM** (inline editierbar; zeigt Spinner + „analysiert" während der Analyse)
   - **Key** (Camelot, grün)
   - **Rating** (1–5 klickbare Sterne)
   - **Genre** (inline editierbar)
   - **Time**

**Verhaltensregeln der Steuerung:**
- **Master-BPM**: jeder neu geöffnete Track wird automatisch auf diese Geschwindigkeit gezogen
  (`rate` aus Verhältnis Master-BPM / Original-BPM, geklemmt auf den Pitch-Bereich, z. B. ±8 %).
- **Master-Key**: jeder neu geöffnete Track wird auf diese Tonart transponiert (nur sinnvoll mit Key-Lock).
- Tempo-`%`-Regler und BPM-Feld sind gekoppelt (Änderung an einem aktualisiert das andere).
- Halbton-Nudge und Camelot-Auswahl sind gekoppelt.

**Master-Key — wichtige Designentscheidung (später zu klären):**
Camelot-Nachbarn liegen 5–7 Halbtöne auseinander → ein hartes „alles auf Master-Key" kann hörbar große
Pitch-Shifts erzeugen. Zwei mögliche Modi (zunächst Modus A bauen, B als spätere Option vormerken):
- **A — „force to master"**: exakt auf Master-Key transponieren.
- **B — „nur kompatibel angleichen"**: nur ±1–2 Halbtöne, sonst Track unverändert lassen.

---

## 6. Projektstruktur

**Aktueller Ist-Zustand** (Xcode-Default, bereits vorhanden):

```
Setify/                         # Repo-Wurzel — hier liegen CLAUDE.md/SPEC.md, hier läuft `claude`
├── CLAUDE.md
├── SPEC.md
├── README.md
├── .gitignore
├── docs/
│   └── mockup-main.html
├── Setify/                     # Quellcode-Ordner der App
│   ├── SetifyApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets/
└── Setify.xcodeproj
```

**In Phase 0 zu entscheiden — zwei Wege für die Code-Organisation:**

- **Weg A (flach, einfach):** Die Core-Logik als Ordnergruppen **im bestehenden `Setify/`-Ordner**:
  ```
  Setify/Setify/
  ├── App/            (SetifyApp.swift, ContentView.swift)
  ├── Models/
  ├── Audio/          (AudioEngine + AVAudioEngine-Impl)
  ├── Analysis/       (Analyzer, Camelot-Mapping, BPM-Oktavkorrektur)
  ├── Library/        (TrackStore, TagLibTrackStore)
  ├── Waveform/       (vDSP 3-Band → RGB; Metal-View)
  ├── Views/          (Header, WaveformView, LibraryTable, TempoChip, KeyChip)
  ├── ViewModels/
  └── Bridge/         (Objective-C++ .mm Wrapper für aubio/libKeyFinder/TagLib + include/)
  ```
  Schnellster Start, alles in einem Target.

- **Weg B (sauber getrennt):** Ein lokales Swift Package `SetifyCore` neben dem App-Ordner, das die
  plattformfreie Logik + Bridge enthält; die App importiert es. Mehr Aufwand beim Einrichten, aber
  bessere Kapselung und der iOS-Port wird trivialer.

Empfehlung: mit **Weg A** starten und auf **Weg B** umstellen, sobald der iOS-Port konkret wird —
die Protokoll-Trennung macht den Umzug später überschaubar. Endgültig in Phase 0 abstimmen.

---

## 7. Umsetzungsphasen

Jede Phase endet lauffähig und wird committet. Vor jeder Phase: Plan zusammenfassen, dann bauen.

**Phase 0 — Bestandsaufnahme & Grundgerüst**
Bestehendes Setify-Projekt sichten. Code-Organisation festlegen (Weg A oder B, siehe §6).
Leere Protokolle (`AudioEngine`, `Analyzer`, `TrackStore`) und Basis-Modelle anlegen. Minimales
SwiftUI-Fenster steht ja schon — eine einzelne Audiodatei über `AVAudioEngine` laden und
Play/Pause/Cue, **ohne** Analyse, ohne Bibliothek.

**Phase 1 — Bibliothek & Tags**
Ordner-Scan (async). TagLib-Bridge: Tags lesen → Tabelle füllen. Inline-Editing der Textspalten und
Sterne. Schreiben über `TagLibTrackStore` (atomar, Schreib-Queue, Kommentar-Erhalt). Rating in `POPM`
**und** Kommentar-Präfix. Tags-only-Implementierung von `TrackStore`.

**Phase 2 — Tempo & Key**
`AVAudioUnitTimePitch` verdrahten. Tempo-Chip + Key-Chip mit Popovers. Master-BPM/-Key-Logik (global-
Schalter). Key-Lock. Kopplung der Regler. Master-Key zunächst Modus A.

**Phase 3 — Analyse**
aubio (BPM, mit DnB-Oktavkorrektur) und libKeyFinder (Key) über die Bridge. Beim Öffnen automatisch
analysieren, falls Wert fehlt. Async, „analysiert"-Zustand in der Tabelle. Ergebnisse in Tags schreiben.

**Phase 4 — RGB-Waveform**
vDSP 3-Band-Analyse + Metal-Rendering. Cue-Marker + Playhead. Klick-zum-Seek. (Optional erst Canvas-
Durchstich, dann Metal.)

**Phase 5 — Politur & iOS-Vorbereitung**
SQLite-Cache hinter `TrackStore` (GRDB). Optional SFBAudioEngine als Decoder-Schicht (Ogg Vorbis,
schnelleres FLAC). Ggf. Umstellung auf Weg B. iOS/iPad-Target anlegen, plattformspezifische Stellen
mit `#if os(...)` kapseln (Dateizugriff via Document Picker, `AVAudioSession`).

---

## 8. Offene Punkte (bewusst später)

- Code-Organisation Weg A vs. B (Phase 0).
- Master-Key Modus A vs. B (siehe §5).
- Crates/Playlists, Suche, Verlauf (kommen mit dem SQLite-Cache).
- Rekordbox „My Tag"-Feinheiten.
- WAV-Tagging-Sonderbehandlung.
- Cue-Points über den einen Cue-Marker hinaus.
