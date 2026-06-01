# STATUS — Setify

Laufendes Protokoll des Projektstands. Begleitend zu `CLAUDE.md` (Leitplanken)
und `SPEC.md` (vollständige Spezifikation und Phasenplan).

---

## Phase 0 — abgeschlossen (Commit `4595666`)

**Build:** `xcodebuild -scheme Setify -destination 'platform=macOS' build` läuft
sauber durch. Eine harmlose Info-Warnung („AppIntents.framework dependency not
found") bleibt — kein Handlungsbedarf.

**Code-Organisation:** Weg B (lokales Swift Package `SetifyCore`) gewählt.

### Was steht

- `SetifyCore` als lokales Swift Package im Repo, eingebunden über
  `XCLocalSwiftPackageReference` im App-Target.
- **Modelle** (plattformfrei, in `SetifyCore`):
  `Track`, `CamelotKey` (1A–12B), `Rating` (0–5), `EditableField`.
- **Protokolle** (gem. SPEC §3): `AudioEngine`, `Analyzer`, `TrackStore` —
  noch ohne `Analyzer`/`TrackStore`-Implementierung.
- **Audio**: `AVAudioEnginePlayer` als erste konkrete `AudioEngine`-Impl.
  - `load/play/pause/seek` über `AVAudioEngine` + `AVAudioPlayerNode`.
  - CDJ-artiges `cue()`: pausiert ⇒ Cue-Punkt = aktuelle Position; spielend ⇒
    Pause und Sprung zurück zum Cue-Punkt.
  - `AVAudioUnitTimePitch`-Knoten ist verdrahtet, aber `rate=1.0` / `pitch=0`.
    Tempo-/Key-UI kommt in Phase 2.
- **App-UI**: `PlayerViewModel` + neue `ContentView`.
  - Datei-Öffnen via NSOpenPanel (Button, ⌘O), Drag & Drop (`.dropDestination`),
    Finder-„Öffnen mit Setify" (`Info.plist` mit `CFBundleDocumentTypes`
    für `public.audio`, `public.mp3`, `public.mpeg-4-audio`,
    `com.apple.m4a-audio`, `com.apple.coreaudio-format`, `org.xiph.flac`,
    `com.microsoft.waveform-audio`, `public.aifc-audio`, `public.aiff-audio`,
    plus `.onOpenURL` in `SetifyApp`).
  - Slider zum Seeken, Cue-/Play-Pause-Buttons, Laufzeit `mm:ss / mm:ss`,
    Space als Play-Pause-Shortcut.

### Bewusst nicht in Phase 0

- Bibliotheks-Scan, TagLib-Bridge, Rating-/BPM-/Key-Schreiben.
- aubio/libKeyFinder-Bindung.
- Tempo-/Key-Steuerung in der UI, Master-BPM/-Key-Logik.
- RGB-Waveform-DSP und Metal-Rendering.

---

## Offene Punkte vor Phase 1

### Sandbox: lesend → schreibend

Das App-Target ist sandboxed mit:

```
ENABLE_APP_SANDBOX           = YES
ENABLE_USER_SELECTED_FILES   = readonly
ENABLE_HARDENED_RUNTIME      = YES
```

Sobald Phase 1 Tags **in die Audiodatei zurückschreibt**, muss

- `ENABLE_USER_SELECTED_FILES = readwrite` gesetzt werden (entitlement
  `com.apple.security.files.user-selected.read-write`), und
- für persistente Bibliothekszugriffe (Ordner über mehrere App-Starts hinweg)
  zusätzlich `com.apple.security.files.bookmarks.app-scope` plus
  Security-Scoped Bookmarks in `TrackStore`.

**Frage an dich:** Stellen wir die Sandbox am Anfang von Phase 1 direkt auf
`readwrite` um (sauber, aber Berechtigung wird sofort breiter), oder erst dann,
wenn der erste Tag-Write fällig ist (kleinerer Schritt, dafür ein zusätzlicher
Migrationscommit mittendrin)? Empfehlung: **direkt am Anfang**, weil der
gesamte `TagLibTrackStore` ohne Schreibrechte ohnehin nicht testbar ist.

### Weitere Klärungen, die wir vor Phase 1 nicht zwingend brauchen, aber gut zu wissen

- **TagLib-Einbindung**: TagLib ist C++. Vorschlag aus SPEC §3 ist die
  `.mm`-Brücke in `SetifyCore/Sources/SetifyCore/Bridge/` mit reinem
  Swift-Interface darüber. Bauoption: TagLib als
  `binaryTarget` (vorgebaute `.xcframework`) oder per Submodule + CMake-Build.
  Vorschlag: erste Iteration mit Homebrew-`libtag` linken, später durch
  `.xcframework` ersetzen — entscheiden wir zu Beginn von Phase 1.
- **Kommentar-Token-Format**: SPEC §4 nennt `★★★★☆ | <rest>` **oder**
  `[R4]`-Token. Vor dem ersten Write festlegen, damit Lese-/Schreibpfad
  konsistent bleibt. Empfehlung: `★`-Variante (menschenlesbar in Serato
  und Rekordbox).

---

## Phase 1 — abgeschlossen

**Build:** `xcodebuild -project Setify.xcodeproj -scheme Setify -destination
'platform=macOS' build` läuft sauber durch.
**Tests:** `swift test` im `SetifyCore`-Paket, 16/16 grün
(`RatingPrefixTests`).

### Entscheidungen aus dem Start von Phase 1

- **Sandbox** wurde sofort auf `readwrite` umgestellt, plus
  `files.bookmarks.app-scope` (für persistente Library-Ordner in Phase 5).
  Eigene `Setify/Setify.entitlements`-Datei als alleinige Quelle der Wahrheit;
  `ENABLE_USER_SELECTED_FILES` aus den Build-Settings entfernt.
- **TagLib** wird via `Vendor/TagLib/build-taglib.sh` reproduzierbar als
  universelles macOS-`.xcframework` (arm64 + x86_64) gebaut und liegt in
  `SetifyCore/Vendor/TagLib.xcframework`. CMake ist Build-Voraussetzung
  (`brew install cmake`).
- **Rating-Kommentar-Token-Format:** `★★★★☆ | <rest>` (menschenlesbar in
  Serato und Rekordbox). Implementiert in `RatingPrefix.parse/format`, mit
  16 Unit-Tests inkl. Round-Trip, Umlauten und Emoji.

### Was steht

- **`SetifyCore`** mit drei Targets in `Package.swift`:
  - `TagLib` (binaryTarget, statisches `.xcframework`)
  - `SetifyCoreObjC` (Objective-C++-Brücke `SetifyTagBridge`)
  - `SetifyCore` (reines Swift) und `SetifyCoreTests`.
- **Brücke**: `readTagsAtPath:` (Title/Artist/Album/Genre/Comment/Year/
  Track + BPM/InitialKey via `PropertyMap` + Audio-Properties) und
  `writeTagsAtPath:…:` (alle Felder, leerer String = entfernen).
- **Swift-Layer**: `TagReader.read(url:) -> Track`, `RatingPrefix`,
  `FolderScanner.scan(folder:) -> AsyncStream<Track>` (rekursiv, gängige
  Audio-Endungen, übersprungene Pakete), `TagLibTrackStore` (Actor) mit
  `save(_:)` (atomar via `itemReplacementDirectory` + `replaceItemAt`)
  und `setActiveTrack(_:)` (lehnt Schreibvorgänge auf die im Player
  geöffnete Datei ab).
- **App-UI**: `ContentView` komponiert Player + Library; neue
  `LibraryView` mit SwiftUI-`Table` (Titel, Artist, BPM, Key, Sterne,
  Genre, Zeit), inline editierbare Textspalten + BPM, klickbare 5-Sterne
  via `StarRatingView`, Doppelklick / Kontextmenü lädt den Track in den
  Player. Editierte Felder werden per 600 ms Debounce an den
  `TagLibTrackStore` weitergereicht. Fehler erscheinen in der Library-
  Toolbar. Menübefehl ⌘⇧O öffnet den Ordner-Picker.
- **Track-Modell** um `comment: String` (bereinigt) ergänzt, damit der
  Nutzer-Kommentar beim erneuten Schreiben erhalten bleibt.

### Bewusst nicht in Phase 1

- **POPM-Schreiben** (ID3-spezifisch). Sterne stehen aktuell nur im
  Kommentarfeld — das ist der für Serato + Rekordbox sichtbare Pfad.
  POPM kommt als kleiner Folgeschritt, sobald sichergestellt ist, dass
  der Kommentar-Pfad in der Praxis funktioniert.
- Persistente Bibliotheks-Ordner (Security-Scoped Bookmarks) — die
  Entitlement ist vorhanden, die Speicherung kommt mit dem SQLite-Cache
  in Phase 5.
- Crates/Playlists, Suche, History (siehe Phase 5).

### Manuell zu prüfen vor Phase 2

- Build läuft, App startet ohne Crash; ein Live-Test mit echtem Ordner
  + Edit eines Tags ist noch offen.
- Empfohlen: erst mit einer **Kopie** eines DJ-Ordners testen, bevor die
  echten Library-Dateien bearbeitet werden.

---

## Phase 2 — abgeschlossen

**Build:** `xcodebuild -project Setify.xcodeproj -scheme Setify -destination
'platform=macOS' build` läuft sauber durch.
**Tests:** `swift test` im `SetifyCore`-Paket, 29/29 grün
(`RatingPrefixTests` + neue `CamelotKeyTests`).

### Entscheidungen aus dem Start von Phase 2

- **Tempo-Slider:** ±8 % um 1.0 (CDJ-Standard). Engine selbst klemmt auf
  0.5–2.0×.
- **Master-Key, Modus A** (exakter Halbton-Shift): bei Mode-Mismatch
  (Dur vs. Moll) bleibt der Track unangetastet. Der Key-Chip zeigt ein
  orangenes Warndreieck, weil Pitch-Shifting Dur nie zu Moll macht.

### Was steht

- **`CamelotKey`** kennt `tonicChromatic` (Quintenzirkel-Formel),
  `semitoneShift(to:)` (gleicher Mode, sonst `nil`), und
  `nudged(bySemitones:)`. 13 Tests, davon ein Round-Trip-Test über alle
  24 Schlüssel × [-12, +12].
- **`PlayerViewModel.loadTrack(_:)`** merkt sich `originalBPM` und
  `originalKey` aus den Track-Tags. `load(url:)` / `unload()` setzen
  beide zurück.
- **`TransportViewModel`** (`@Observable`) hält `masterBPM`, `masterKey`,
  `keyLock`, die `isGlobal`-Flags und liefert `effectiveBPM`/
  `effectiveKey` für die UI. `applyMasterToLoadedTrack()` wird aus
  `ContentView.onChange(loadedURL)` getriggert und schreibt `rate` und
  `pitchCents` auf den Player.
- **Tempo-Chip + Popover:** zeigt effektive BPM und „global"-Marker.
  Popover hat BPM-Feld, ±8 %-Slider mit Live-%-Anzeige, Reset (rate = 1).
- **Key-Chip + Popover:** zeigt effektive Camelot-Tonart in Grün,
  „global"-Marker und bei Mismatch ein orangenes Warnsymbol. Popover
  enthält ein 12×2-Grid (Moll/Dur), Halbton-Nudge (−/+) und Reset auf
  den Original-Key.
- **Key-Lock-Toggle** (Schloss-Icon) rechts neben den Chips. Mappt auf
  `AVAudioUnitTimePitch.rate` (entkoppelt von Pitch) und stützt sich auf
  die Phase-0-Verdrahtung des Time-Pitch-Knotens.

### Bewusst nicht in Phase 2

- **Master-Key Modus B** („nur kompatibel angleichen", ±1–2 Halbtöne):
  als spätere Option vorgemerkt.
- **Persistenz** von Master-Werten über App-Starts hinweg (Defaults o. ä.).
  Aktuell sind Master-Werte session-only.

---

## Phase 3 — abgeschlossen

**Build:** `xcodebuild -project Setify.xcodeproj -scheme Setify -destination
'platform=macOS' build` läuft sauber durch.
**Build-Dependencies:** Zusätzlich zu CMake/Xcode jetzt `python@3.11`
(für aubio's waf). `brew install python@3.11`.

### Entscheidungen aus dem Start von Phase 3

- **BPM-Oktavkorrektur** als Preset wählbar (Universal/DnB/House/HipHop/
  Disco). Default: Universal 75–185. Picker in der Library-Toolbar.
- **Auto-Analyse-Trigger:** beim Laden eines Tracks aus der Library
  **plus** Batch-Button („Fehlende analysieren") in der Library-Toolbar.
- **Key-Confidence:** libKeyFinders Top-Schätzung wird immer übernommen.
  DJ korrigiert manuell, falls nötig.

### Was steht

- **aubio 0.4.9** als universelle macOS-`.xcframework` über
  `Vendor/aubio/build-aubio.sh`. Nutzt Apple Accelerate (vDSP) für FFT —
  keine fftw-Abhängigkeit. Die aubio-Quellen kommen aus dem Tarball, das
  gebundelte waf wird durch waf 2.1.6 ersetzt (aubio-waf 0.4.9 läuft
  nicht auf Python ≥ 3.12).
- **libKeyFinder 2.2.6** (Mixxx-Fork) als `.xcframework` über
  `Vendor/KeyFinder/build-keyfinder.sh`. fftw3 3.3.10 wird mitgebaut,
  die beiden statischen Archive werden via `libtool` zu einem
  zusammengeführt.
- **Bridge** (`SetifyAnalyzerBridge.mm`): nimmt mono Float32-PCM von
  Swift entgegen und ruft aubio (Tempo-Tracking, win 1024 / hop 512)
  bzw. libKeyFinder; key_t → Camelot-Notation.
- **Swift-Layer** in `SetifyCore/Analysis/`: `PCMLoader` (AVAudioFile →
  mono Float32-Data, in 16k-Frame-Blöcken), `BPMRangePreset` mit
  `corrected(_:)`-Heuristik (Verdoppeln/Halbieren auf den Bereich),
  `AubioBPMAnalyzer`, `KeyFinderAnalyzer`, `AnalysisCoordinator`
  (dekodiert einmal, fragt beide Analyzer, serialisiert Anfragen).
- **LibraryViewModel** erhält `analysisState`-Map, `bpmPreset`,
  `analyzeIfNeeded(_:)`, `analyzeAllMissing()`. Ergebnisse landen
  sofort (ohne 600-ms-Debounce) über den `TagLibTrackStore` in die
  Datei.
- **UI** (`LibraryView`-Toolbar): Preset-Menü, Batch-Button mit
  Zähler offener Analysen, Mini-Spinner in BPM-/Key-Zellen, solange die
  Analyse für die Zelle läuft.

### Bewusst nicht in Phase 3

- **POPM-Schreiben** — Rating bleibt vorerst nur im Kommentarfeld.
- **fortgeschrittene Confidence-Logik** für Key-Erkennung.
- **iOS-/x86_64-Audio-Decode-Fallback** (z. B. SFBAudioEngine für Ogg
  Vorbis): wartet, bis ein Praxisfall auftaucht.

### Manuell zu prüfen vor Phase 4

- Ein Track ohne BPM/Key in die Library aufnehmen, doppelklicken: BPM-
  und Key-Zelle sollten innerhalb weniger Sekunden befüllt sein und in
  Serato/Rekordbox nach dem Reload erscheinen.
- Batch-Button auf einem Test-Ordner mit ~10 Tracks: Spinner pro Zeile,
  alle Werte werden geschrieben.

---

## Phase 4 — abgeschlossen

**Build:** `xcodebuild -project Setify.xcodeproj -scheme Setify -destination
'platform=macOS' build` läuft sauber durch.
**Tests:** `swift test` im `SetifyCore`-Paket, 36/36 grün (3 neue
`WaveformAnalyzerTests`).

### Entscheidungen aus dem Start von Phase 4

- **Cache-Strategie:** in-memory pro Session via `WaveformCache`
  (Actor). Disk-Cache wandert nach Phase 5 (SQLite-Cache).
- **Frequenzgrenzen** wie in SPEC §2/§5: Bass < 200 Hz,
  Mitten 200 Hz–2 kHz, Höhen > 2 kHz.
- **Klick auf die Waveform = sofortiges Seek.** Drag-Funktionalität
  ist heute „Tap zum Springen" — späterer Scrubbing-Modus möglich.
- **Renderer:** SwiftUI Canvas. Metal-Upgrade wäre Phase 5+
  (Performance reicht bisher locker).

### Was steht

- **WaveformBin** (rms + bass/mid/high, alle Float 0…1) und
  **WaveformData** (Bins + Sample-Rate + Sekunden pro Bin) als reine
  Sendable-Werte.
- **WaveformAnalyzer**: vDSP-FFT in 1024-Sample-Hann-Fenstern mit
  50 %-Overlap. Energie pro Band wird über Index-Slicing aus den
  Magnituden gezogen. Track-weite Normalisierung mit einem
  gemeinsamen Max für die drei Bänder — sonst würden dominante
  Frequenzbereiche optisch nicht stechen.
- **WaveformCache** (Actor): hält Resultate im Speicher, dedupliziert
  parallele Anfragen über einen `Task`-Map.
- **WaveformView** (SwiftUI Canvas): downsamplt Bins auf die View-
  Pixel-Breite. Vor dem Playhead voll, dahinter abgedunkelt.
  Cue-Marker unten in Orange, weisser Playhead, Tap = Seek.
- **WaveformViewModel** (`@Observable`): verwaltet Lade-/Race-State,
  cancelt alte Tasks bei schnellen Track-Wechseln.
- **ContentView** platziert den Waveform-Streifen zwischen Zeitleiste
  und Chip-Bar. Spinner während die Analyse läuft, dezenter
  Fehlertext (orange) bei Decode-Problemen.

### Bewusst nicht in Phase 4

- **Metal-Renderer** — Canvas reicht für die Trackgrößen, mit denen
  wir aktuell rechnen. Performance-Optimierung kommt erst, wenn
  sie nötig wird.
- **Persistenter Waveform-Cache** — die rohen Bin-Arrays könnten
  pro Track als Datei gecachet werden. Hängt am SQLite-/Datei-
  Cache aus Phase 5.
- **Scrubbing** (Drag mit Live-Position) — heute Tap-and-Seek.
- **Beat-/Downbeat-Marker** auf der Waveform — kommt ggf. parallel
  zur BPM-Analyse-Verfeinerung später.

---

## Nachträge nach Phase 4 (Bugfixes & Politur)

Eine Reihe von Praxis-Bugs, die nach dem Live-Test sichtbar wurden:

- **PCMLoader-Format-Mismatch** (Commit `9673de9`): Die Analyse blieb bei
  Stereodateien stumm, weil `AVAudioFile.read(into:)` einen Buffer
  verlangt, der dem `processingFormat` der Datei entspricht
  (typischerweise Float32 *non-interleaved*). Der PCMLoader hat einen
  eigenen `interleaved: true`-Buffer gebaut — bei Mono zufällig OK,
  bei Stereo Crash im Stillen. Behoben + Tests, die Mono/Stereo round-
  trippen.
- **Player-Chips ohne Reaktion** (Commit `c2d626c`): `rate` und
  `pitchCents` waren Computed-Properties auf `AVAudioUnitTimePitch` —
  Observation-Framework hat sie nicht getrackt, also haben die Chips
  Änderungen verschluckt. Jetzt stored properties mit `didSet`-Sync.
- **Analyse-Werte erreichten den Player nicht** (gleicher Commit): beim
  Doppelklick eines Tracks ohne BPM/Key blieben `player.originalBPM/
  originalKey` `nil`. `LibraryViewModel.onTrackAnalyzed`-Hook zieht die
  Werte nach Abschluss der Analyse nach.
- **Schreibvorgang an aktiver Datei wurde nie nachgeholt**
  (Commit `f4ad9c6`): `TagLibTrackStore.save` lehnt mit `fileInUse`
  ab, wenn die Datei gerade im Player läuft. `LibraryViewModel` merkt
  sich das in `blockedByActivePlayer`, der rote Punkt bleibt sichtbar,
  und beim Entladen/Wechsel des Tracks wird der Save automatisch
  ausgeführt.
- **Waveform-Farben** (Commits `86bf164` → `640cb95`): Hintergrund
  reagiert jetzt auf den ColorScheme (weiss/schwarz). Höhen hatten im
  DSP strukturell ~100× mehr Bins als Bass — die FFT-Summen wurden
  daher *pro Band* durch die Bin-Anzahl geteilt, bevor track-weit
  normiert wird. Im Renderer reichte `sqrt()` nicht; mit `pow(0.4)`
  werden mittlere Energien deutlich knackiger.
- **Seek während Wiedergabe sprang an den Trackanfang**
  (Commit `fce3537`): `AVAudioPlayerNode.scheduleSegment` ruft den
  Completion-Handler auch dann, wenn der Segment durch ein
  anschliessendes `stop()` abgebrochen wurde. Der Handler hat das nicht
  unterschieden und alles auf null gesetzt. Lösung:
  `scheduleGeneration`-Zähler, die Closure ignoriert Callbacks zu
  Schedules, die längst überholt sind.
- **Erscheinungsbild manuell wählbar** (gleicher Commit):
  System/Hell/Dunkel über das neue Menü „Ansicht", persistiert via
  `@AppStorage` und appliziert über `.preferredColorScheme(...)`.

---

## Phase 5a — abgeschlossen

SQLite-Persistenz und Multi-Folder. iOS-Target (5b) und SFBAudioEngine
(5c) stehen noch aus.

### Was steht

- **GRDB.swift 7.x** als SPM-Dep in `SetifyCore`. `DatabaseService`
  (Actor) liegt unter Application Support; Migration `v1` mit drei
  Tabellen: `tracks` (URL als Primary Key, Metadaten + Audio-Properties
  + mtime/cached_at), `waveforms` (URL/mtime/bins-Blob; 4 Float32 pro
  Bin), `folders` (UUID/URL/name/bookmark_data/added_at).
- **CachedTrack / CachedWaveform / FolderRecord** als GRDB-Records.
- **LibraryRepository** (Actor, `TrackStore`-konform) orchestriert
  `TagLibTrackStore` + `DatabaseService`. `loadTrack(url:)` macht
  Cache-First mit mtime-Vergleich und fällt sonst auf `TagReader`
  zurück. `scan(folder:)` streamt durch den Cache, was den App-Restart
  praktisch lautlos macht.
- **WaveformCache** nimmt eine optionale `DatabaseService` an und prüft
  bei jeder Anfrage die DB (Stale-Check via mtime). Frische
  Berechnungen werden persistiert.
- **Security-Scoped Bookmarks**: NSOpenPanel-Pick erzeugt ein
  Bookmark, das im `FolderRecord` persistiert wird. Beim App-Start
  resolved `restoreSavedFolders` alle Bookmarks; der zuletzt
  gewählte Ordner wird automatisch aktiv. Stale Bookmarks werden
  refresht, unbrauchbare gelöscht.
- **Multi-Folder-Sidebar**: `LibraryView` hat jetzt eine 200-px-
  Sidebar mit „Quellen"-Liste und „Ordner hinzufügen…"-Button.
  Klick auf eine Quelle wechselt die Anzeige; Kontextmenü erlaubt
  „Quelle entfernen". Aktive Quelle wird unten in der Status-
  Zeile ausgewiesen.
- **Position-Slider entfernt** — gesucht wird ausschliesslich über
  die Waveform (Tap = Seek).

### Bewusst nicht in Phase 5a

- **Multi-Source-Aggregation** („Alle Tracks"-Ansicht über mehrere
  Ordner hinweg). Aktuell zeigt die Tabelle immer nur eine Quelle.
- **Crates / Playlists / History** — die SQLite-Basis ist da, die
  konkreten Features kommen in einer eigenen Phase.
- **Disk-Cache für PCM-Decodes** (für noch schnellere Waveform-
  Berechnung) — nicht nötig, solange die Waveform-Blobs gecached
  werden.

---

## Phase 5b — geplant (iOS/iPad)

Plattform-Vorbereitung:

- xcframeworks (TagLib, aubio, KeyFinder) um iOS-Slices erweitern:
  iOS-arm64-Device + iOS-arm64-Simulator + x86_64-Simulator. Die
  bestehenden Build-Skripte in `Vendor/` müssen entsprechend
  ausgebaut werden.
- iOS/iPad-Target im Xcode-Projekt anlegen. Code, der auf NSOpenPanel/
  NSApplicationDelegate/AppKit verweist, mit `#if os(macOS)` kapseln;
  DocumentPicker als iOS-Pendant.
- `AVAudioSession`-Konfiguration für iOS einrichten (Category playback,
  Background-Audio, Interruption-Handling).
- ColorScheme- und Appearance-Toggle bleiben SwiftUI-übergreifend.

## Phase 5c — optional (SFBAudioEngine)

- Ogg Vorbis / WavPack / Monkey's Audio-Unterstützung via
  SFBAudioEngine. Erst einziehen, wenn die Library es verlangt.
