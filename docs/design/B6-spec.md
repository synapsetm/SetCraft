# Mac-Redesign B6 · Deck / Amber / Systemschrift

Referenz-Mockup: Claude-Design-Canvas «SetCraft Redesign», Board **B6 · Amber – Systemschrift (SF Pro)**
https://claude.ai/artifact/KvZzLZi2Bk2uMz13jfcjDz

Tokens: `SetCraft/Theme.swift` (Farben, Schrift, Masse). Keine Hex-Werte direkt in Views.

## Spielregeln
- **Nur Darstellung.** Keine Änderungen an ViewModels, Analyse, Tag-Schreiben, DB oder SetCraftCore-Logik.
  Ausnahme: reine Anzeige-Helper (z. B. formatierte Strings) dürfen in die View-Schicht.
- Bestehende Funktionen bleiben erreichbar (Tempo/Key-Chips mit global setzen, MetadataFixSheet,
  DefaultPlayerSheet, Updater, Drag & Drop, Tastatur-Shortcuts, Kontextmenüs).
- Berechnete Werte (gespielter Key/BPM) werden weiterhin **nie** persistiert (SPEC §5b).
- App ist dunkel: `preferredColorScheme(.dark)` am Hauptfenster.
- Ziffern immer `.monospacedDigit()` auf SF Pro – **kein** `design: .monospaced`
  (Ausnahme: Dateinamen/Pfade in MetadataFixSheet).
- Camelot-Farben: bestehendes `CamelotKey.color` (SetCraftCore) unverändert lassen.
  Grenzfall-Farbe (Tilde) aus `Theme.Palette.keyAmbiguous` statt Inline-Wert in `SoundingKeyLabel`.
- iOS-Target bleibt vorerst unverändert.

## Layout (oben → unten)
1. **Header** (Höhe ~40): links «SETCRAFT» (`Typo.brand`, Tracking 2.1, Farbe `accent`);
   rechts Quelle + Anzahl, z. B. «BEATPORT WEEKEND 35 · 53 TRACKS» (`themeLabel()`). Trennlinie `border`.
2. **Now-Playing-Raster**, 6 Spalten mit vertikalen Trennlinien `border`, Padding 16/22:
   | TRACK (2 Spalten) | BPM | KEY | ELAPSED | REMAIN |
   - Label oben (`themeLabel()`), Wert darunter.
   - TRACK: Titel `Typo.title` `text`, Artist `Typo.artist` `textSecondary`, einzeilig mit Ellipsis.
   - BPM: `Typo.readout` in `accent` (gespielter BPM; Klick öffnet bestehende Tempo-Funktion aus TempoChip).
   - KEY: `Typo.readout` in Key-Farbe (gespielter Key; Klick → KeyChip-Funktion; Shift-Darstellung `8A → 9A` beibehalten).
   - ELAPSED `text`, REMAIN mit «-» in `textSecondary`, beide `Typo.readout`.
3. **Waveform** volle Breite, Höhe `Metrics.waveformHeight` (148), Hintergrund `waveformBG`,
   Beatgrid-Linien `beatgrid`, Playhead 2 px `accent` mit kleinem Dreieck oben,
   Cue-Linie `cue` mit Label «CUE» (`cueLabel`, 11 medium). RGB-Rendering von WaveformView bleibt.
4. **Transport-Zeile** (Padding 16, Abstand 8), alle Buttons Höhe 44, Radius 2,
   Hintergrund `surface`, Rahmen `borderStrong`:
   Prev (52) · **Play/Pause (84, Füllung `accent`, Icon `onAccent`)** · Next (52) · «CUE» ·
   «KEY LOCK» mit kleinem gefülltem Quadrat in `accent` wenn aktiv · Sterne-Rating (17 pt, `star`/`starDim`) ·
   Spacer · «•••» (Menü mit bisherigen Zusatzaktionen).
5. **Unterer Bereich** horizontal geteilt:
   - **Sources-Sidebar** (`Metrics.sidebarWidth`, Rahmen rechts `border`): Label «SOURCES»,
     Einträge mit Nummer «01»–«05» (`textMuted`, monospacedDigit) + Ordnername (`text`).
     Aktiver Eintrag: Hintergrund `selection`, 3 px Kante links `accent`, Nummer in `accent`.
     Unten «+ ADD FOLDER» (Button-Stil Label, `textSecondary`).
   - **Library**: Toolbar mit Filterfeld (Lupe, Platzhalter «Filter 53 tracks», `surface` + `border`),
     Button «ANALYZE MISSING (16)» (Outline `accent`, Text `accent`), rechts «1 ISSUE»
     (Rahmen `issueBorder`, Text `issueText`, öffnet MetadataFixSheet).
     Tabelle: Spalten `# · TITLE · ARTIST · BPM · KEY · RATING · TIME`, Kopf mit `themeLabel()` und Sortierpfeil,
     Zeilenhöhe 32, Trennlinien `rowDivider`, Zahlen rechtsbündig `bodyNumeric`,
     KEY in Key-Farbe semibold (Shift `8A → 9A`, Tilde), Rating als Sterne `star`/`starDim`.
     Ausgewählte/aktive Zeile: `selection` + 3 px Kante links `accent`; spielender Track Titel in `accent`.
     Footer: «53 TRACKS · 16 WITHOUT BPM · RANGE 75–185» (`themeLabel()`), Trennlinie oben `border`.

## Mapping auf Dateien (Mac-Target `SetCraft/`)
| Bereich | Datei(en) |
|---|---|
| Fenster-Aufbau, Header, Now-Playing, Transport | `ContentView.swift`, `TransportViewModel` nur lesen |
| BPM-/Key-Readouts | `TempoChip.swift`, `KeyChip.swift`, `SoundingKeyLabel.swift` |
| Waveform | `WaveformView.swift` (Farben/Hintergrund/Playhead/Cue, nicht die Analyse) |
| Sidebar, Toolbar, Tabelle, Footer | `LibraryView.swift` |
| Sterne | `StarRatingView.swift` |
| Sheets (später, gleiche Tokens) | `MetadataFixSheet.swift`, `DefaultPlayerSheet.swift` |

## Vorgehen (je Schritt bauen, prüfen, committen)
1. `Theme.swift` kompiliert, `preferredColorScheme(.dark)` + Hintergrund.
2. Header + Now-Playing-Raster.
3. Waveform-Styling.
4. Transport-Zeile.
5. Sidebar + Library-Toolbar.
6. Tabelle + Footer.
7. Sheets angleichen, Feinschliff, Screenshot nach `docs/screenshots/`.
