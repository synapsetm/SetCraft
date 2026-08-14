# SPEC.md — Vollständige Projektspezifikation (SetCraft)

> Begleitdokument zu `CLAUDE.md`. Hier stehen die Details und Begründungen.
> Bei Konflikten gewinnt `CLAUDE.md` für die harten Regeln; dieses Dokument liefert den Kontext.

---

## 1. Ziel & Rahmen

Ein DJ-orientierter Musikplayer („SetCraft") für **macOS** (zuerst), mit vorbereitetem **iOS**-Port (iPhone).
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

Ob die Core-Logik ein eigenes Swift Package `SetCraftCore` wird oder eine Ordnergruppe im bestehenden
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

## 5b. Verschobene Tonarten bei Tempoänderung (Anzeige-Feature)

> Nicht zu verwechseln mit **Phase 5b (iOS-Target)** in `STATUS.md` — hier ist der
> Spezifikationsabschnitt gemeint, nicht die Umsetzungsphase.

### Physikalischer Hintergrund
Ohne Key-Lock verschiebt eine Tempoänderung zwangsläufig die Tonhöhe (schnelleres Abspielen =
höhere Frequenzen). Faustregel: ~6 % Tempoänderung ≈ 1 Halbton.

### Formeln
```swift
/// Halbtonverschiebung aus dem Geschwindigkeitsverhältnis (rate = zielBPM / originalBPM)
func semitoneShift(forRate rate: Double) -> Double { 12 * log2(rate) }

/// Cents (für AVAudioUnitTimePitch.pitch)
func cents(forRate rate: Double) -> Double { 1200 * log2(rate) }

/// Umkehrung: nötige Rate für n Halbtöne
func rate(forSemitones n: Double) -> Double { pow(2, n / 12) }
```
Ablauf pro Track: `rate = masterBPM / trackBPM` → `st = 12·log2(rate)` → `n = round(st)` →
Pitch-Class des Original-Keys um `n` verschieben → zurück auf Camelot mappen.

### Voraussetzung: Key-Lock-Schalter
`AVAudioUnitTimePitch` entkoppelt Rate und Pitch konstruktionsbedingt — die App verhielt sich
daher bis zu diesem Feature **immer** wie „Key-Lock an". Das Anzeige-Feature setzt einen echten
Key-Lock-Schalter voraus: ist er **aus**, folgt die Tonhöhe der Rate
(`pitch = userPitch + 1200·log2(rate)`), ist er **an**, bleibt sie unangetastet.

### Anzeige in der Bibliothek (Variante A — inline in der Key-Spalte)
Nur aktiv, wenn **Master-BPM gesetzt UND Key-Lock AUS** ist:
- Format: `<Original ausgegraut> → <klingender Key farbig>`, z. B. `8A → 9A`.
- Keine Verschiebung (`n == 0`) → nur der Original-Key plus dezentes `—`.
- **Tilde-Markierung** `~9A` bei Grenzfällen: wenn `abs(st - round(st)) > 0.40`, klingt der Track
  „zwischen" zwei Tonarten; die Rundung ist dann willkürlich. Tilde in Warnfarbe (`#FF9F45`).
  Schwellwert 0.40 ist ein Startwert und mit echter Library nachzujustieren.
- Über der Liste ein Hinweisbanner: „Key lock aus — Tonarten verschieben sich mit dem Tempo."
- Bei Key-Lock AN: Banner und Pfeile verschwinden, es wird nur der Original-Key gezeigt.

### Sortierung
Beim Sortieren nach Key wird der **berechnete, klingende Key** als Sortierschlüssel verwendet,
nicht der Wert aus dem Tag. Sortierreihenfolge nach Camelot-Zahl (1A, 2A, 3A …), damit harmonisch
benachbarte Tracks in der Liste beieinanderstehen. Bei Key-Lock AN wird wieder nach dem Original
sortiert. Ändert sich die Master-BPM, ordnet sich die Liste entsprechend neu.

### KRITISCH: berechnete Werte werden NIEMALS persistiert
Die verschobenen Keys sind eine reine **Laufzeit-Darstellung** des aktuellen Wiedergabezustands.

- **Nicht in die Datei-Tags schreiben** — weder `TKEY`/`INITIALKEY` noch das Kommentarfeld.
  In den Tags steht immer und ausschließlich der **analysierte Original-Key** des Materials.
- **Nicht in den Cache/die DB schreiben** — auch im SQLite-Cache steht nur das Original.
- Gleiches gilt sinngemäß für die **BPM**: In die Datei geht die Original-BPM des Tracks,
  niemals die durchs Master-Tempo angepasste Wiedergabe-BPM.
- Ein „Save"/„Write tags"-Vorgang muss die Werte also immer aus dem Original-Modellfeld nehmen,
  nie aus dem für die Anzeige berechneten Feld.

**Konsequenz fürs Datenmodell:** Original- und Anzeigewert strikt trennen, z. B.
`track.key` (persistiert, aus Analyse/Tag) vs. `track.playingKey` (berechnet, nie gespeichert).
Analog `track.bpm` vs. `track.playingBPM`. Nur die erstgenannten Felder sind je Ziel eines Tag-Writes.

Da die Berechnung den Wiedergabezustand (Master-BPM, Key-Lock) braucht, den `Track` als reiner
Wert nicht kennt, sind `playingKey`/`playingBPM` als **Methoden mit Zustandsparameter** umgesetzt
(`track.playingKey(masterBPM:keyLock:)`), nicht als parameterlose Computed Properties. Der
entscheidende Punkt bleibt: sie sind nicht Teil des gespeicherten Zustands.

---

## 6. Projektstruktur

**Aktueller Ist-Zustand** (Xcode-Default, bereits vorhanden):

```
SetCraft/                         # Repo-Wurzel — hier liegen CLAUDE.md/SPEC.md, hier läuft `claude`
├── CLAUDE.md
├── SPEC.md
├── README.md
├── .gitignore
├── docs/
│   └── mockup-main.html
├── SetCraft/                     # Quellcode-Ordner der App
│   ├── SetCraftApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets/
└── SetCraft.xcodeproj
```

**In Phase 0 zu entscheiden — zwei Wege für die Code-Organisation:**

- **Weg A (flach, einfach):** Die Core-Logik als Ordnergruppen **im bestehenden `SetCraft/`-Ordner**:
  ```
  SetCraft/SetCraft/
  ├── App/            (SetCraftApp.swift, ContentView.swift)
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

- **Weg B (sauber getrennt):** Ein lokales Swift Package `SetCraftCore` neben dem App-Ordner, das die
  plattformfreie Logik + Bridge enthält; die App importiert es. Mehr Aufwand beim Einrichten, aber
  bessere Kapselung und der iOS-Port wird trivialer.

Empfehlung: mit **Weg A** starten und auf **Weg B** umstellen, sobald der iOS-Port konkret wird —
die Protokoll-Trennung macht den Umzug später überschaubar. Endgültig in Phase 0 abstimmen.

---

## 7. Umsetzungsphasen

Jede Phase endet lauffähig und wird committet. Vor jeder Phase: Plan zusammenfassen, dann bauen.

**Phase 0 — Bestandsaufnahme & Grundgerüst**
Bestehendes SetCraft-Projekt sichten. Code-Organisation festlegen (Weg A oder B, siehe §6).
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
schnelleres FLAC). Ggf. Umstellung auf Weg B. iOS-Target (iPhone) anlegen, plattformspezifische Stellen
mit `#if os(...)` kapseln (Dateizugriff via Document Picker, `AVAudioSession`).

---

## 8. Offene Punkte (bewusst später)

- Code-Organisation Weg A vs. B (Phase 0).
- Master-Key Modus A vs. B (siehe §5).
- Crates/Playlists, Suche, Verlauf (kommen mit dem SQLite-Cache).
- Rekordbox „My Tag"-Feinheiten.
- WAV-Tagging-Sonderbehandlung.
- Cue-Points über den einen Cue-Marker hinaus.
