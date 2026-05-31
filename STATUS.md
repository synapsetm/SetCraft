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

## Phase 1 — geplant (SPEC §7)

Sobald oben grünes Licht:

1. Ordner-Scan (async, Hintergrund-Task), `Track`-Liste in der UI.
2. TagLib-Bridge: Tags lesen → Tabelle füllen.
3. Inline-Editing der Textspalten (Titel, Artist, Album, Genre) und
   Sterne-Klick.
4. `TagLibTrackStore`: atomar schreiben (Temp-Datei → Rename), Schreib-Queue,
   Kommentar erhalten (nur das Sterne-Präfix ersetzen), Rating doppelt
   (`POPM` **und** Kommentar-Präfix).
5. Tags-only-Implementierung von `TrackStore` (SQLite-Cache kommt erst in
   Phase 5).
