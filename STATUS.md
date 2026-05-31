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

## Phase 3 — geplant (SPEC §7)

Automatische Analyse:

- aubio-Binding über die Bridge (mit DnB-Oktavkorrektur).
- libKeyFinder-Binding über die Bridge.
- Beim Öffnen eines Tracks ohne BPM/Key automatisch analysieren, async
  im Hintergrund, „analysiert"-Zustand in der Tabelle anzeigen.
- Ergebnisse über den `TagLibTrackStore` in die Datei-Tags schreiben.
