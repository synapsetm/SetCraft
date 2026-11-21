# iOS-Redesign I1 · Amber (Gegenstück zu B6)

> **Verbindliche Spec: [`../I1-spec.md`](../I1-spec.md).** Diese README ist der ursprüngliche Entwurf zu den Mockups;
> bei Abweichungen gilt `I1-spec.md` (dort u. a. Funktionsinventar, Theme-Entscheid, Swipe-Aktionen, Zoom-Persistenz).

Referenz-Mockups (im Browser öffnen, interaktiv):

| Datei | Screen | Interaktion im Mockup |
|---|---|---|
| `player.html` | Player-Tab | Waveform ziehen = Scrubben · Pinch bzw. −/+ (Ctrl+Mausrad) = Zoom · Sterne antippen |
| `library.html` | Library-Tab | Quellenname antippen = Quellen-Menü · ••• = Aktionen · Track nach links wischen = ANALYZE |
| `complete-tags.html` | Sheet «Complete missing tags» | Checkboxen antippen |

Die Icons in den Mockups sind Tabler-Icons (CDN). In der App **SF Symbols** verwenden.

Stilvorlage ist das Mac-Redesign B6 (`docs/design/B6-spec.md`, `docs/screenshots/mac/main.png`).

## Spielregeln
- **Nur Darstellung.** Keine Änderungen an Stores, Analyse, Tag-Schreiben oder SetCraftCore-Logik.
  Reine Anzeige-Helper (formatierte Strings, Zoom-Umrechnung) dürfen in die View-Schicht.
- **Tokens aus `Theme.swift`** (Farben, Schrift, Masse) — keine Hex-Werte in Views.
  `Theme.swift` liegt heute nur im macOS-Target: per Target Membership zusätzlich ins iOS-Target
  aufnehmen oder in einen gemeinsamen Ordner verschieben. Nicht duplizieren.
- Bestehende iOS-Funktionen bleiben erreichbar: `TempoSheet` (inkl. global setzen), `TagEditSheet`,
  `TrackInfoSheet`, `MasterTempoBar`, `NowPlayingManager`/Lock Screen, Mini-Player.
- Berechnete Werte (gespielter Key/BPM) werden **nie** persistiert (SPEC §5b).
- App ist dunkel: `.preferredColorScheme(.dark)`.
- Ziffern immer `.monospacedDigit()` auf SF Pro, kein `design: .monospaced`
  (Ausnahme: Dateinamen im Complete-Tags-Sheet).
- Camelot-Farben unverändert aus `CamelotKey.color`.
- Labels in Grossbuchstaben mit Tracking über den bestehenden `themeLabel()`-Stil.
- Texte über `SetCraft iOS/Localizable.xcstrings`; danach `scripts/check-localization.py --target ios`.
- Touch-Ziele mindestens 44 × 44 pt.

## Navigation
- Tab-Leiste mit genau zwei Tabs: **LIBRARY** und **PLAYER**. Aktiver Tab in `accent`.
- Kein eigener Quellen-Tab: Quellen werden über das Quellen-Menü in der Library verwaltet.

## Player (`PlayerScreen.swift`, `WaveformCanvasView.swift`) — siehe `player.html`
Reihenfolge oben → unten:
1. **Kopfzeile:** Cover 46 × 46 pt (`ArtworkView`, Radius 3), daneben Label TRACK, Titel (einzeilig, Ellipsis),
   Artist `textSecondary`; rechts `•••` (öffnet bestehende Track-Aktionen/`TrackInfoSheet`).
   Ohne Cover: Platzhalter gleicher Grösse mit Noten-Symbol.
2. **Waveform**, Höhe ~220 pt, volle Breite, Trennlinien oben/unten:
   - **Playhead fest in der Mitte**, Farbe `accent`, 2 pt, mit kleinem Dreieck oben. Bereich links davon abgedunkelt.
   - **Scrubben:** horizontales Ziehen verschiebt den Track unter dem Playhead.
   - **Fortschrittsbalken** 2 pt am oberen Rand (`accent`) = Position im ganzen Track.
   - **Zeit in der Waveform:** ELAPSED oben links, REMAIN oben rechts, auf halbtransparentem dunklem Hintergrund.
   - **Zoom** unten rechts: Kapsel `−  8 BARS  +` und Pinch. Stufen in Takten: 1 · 2 · 4 · 8 · 16 · 32 · 64, Standard 8.
     Umrechnung: `pointsPerSecond = width / (bars × 4 × 60 / playingBPM)` → Zoom bleibt bei Tempoänderung in Takten stabil.
   - **Beatgrid:** ≤ 4 bars → Linie pro Beat; ≤ 16 bars → pro Takt; darüber alle 4 Takte. Taktlinien etwas heller.
   - Gesten: `DragGesture` (Scrub) und `MagnifyGesture` (Zoom) mit `.simultaneously`/Priorität, damit der
     Playhead beim Aufsetzen des zweiten Fingers nicht springt.
3. **Kacheln** (2 Spalten, Trennlinie dazwischen): links BPM-Label + Chevron und Wert in `accent` (Antippen öffnet
   `TempoSheet`), rechts KEY-Label und gespielter Key in Camelot-Farbe (Tilde-Logik wie macOS). Wert ~30 pt.
   **Keine** ELAPSED/REMAIN-Kacheln (die Zeit steht in der Waveform).
4. **Transport** (vertikal zentriert im Restraum): Previous und Next als Quadrate mit Rahmen (56 × 46),
   Play/Pause als breiter gefüllter `accent`-Block (104 × 46), Symbol dunkel.
5. **Rating:** 5 Sterne, je ~32 pt, eigene Zeile, aktiv `accent`, inaktiv gedimmt.

## Library (`ContentView.swift`, `TrackRowView.swift`, `MiniPlayerView.swift`) — siehe `library.html`
1. Oben links «SETCRAFT» (`accent`, Tracking), rechts `•••`-Menü:
   Open file… · Re-analyze all · Complete tags · BPM range · Reset plays.
2. **Quellenzeile:** Nummer in `accent` («01»), Quellenname, Chevron, rechts «105 TRACKS».
   Antippen öffnet das **Quellen-Menü**: nummerierte Quellen (aktive mit `accent`-Kante), Papierkorb je Quelle,
   darunter «Add folder…».
3. **Filterfeld** + Button «ANALYZE n» (Rahmen in `accent`, nur sichtbar wenn n > 0).
4. Kopfzeile «ARTIST ↑» / «BPM · KEY» als Sortierhinweis.
5. **Zeile:** Titel (laufender Track in `accent` mit ▶), Artist `textSecondary`, kleine Sterne;
   rechts BPM (monospacedDigit) und Key in Camelot-Farbe. Keine weiteren Spalten auf dem iPhone.
6. **Swipe nach links:** Aktion ANALYZE (`accent`-Hintergrund, dunkle Schrift) via `.swipeActions`.
7. **Mini-Player** über der Tab-Leiste: Cover 34 pt, Titel, «Artist · BPM · Key», Play/Pause als `accent`-Quadrat.

## Complete Tags (`SetCraft iOS/MetadataFixSheet.swift`) — siehe `complete-tags.html`
- Als **Bottom Sheet** (`.presentationDetents([.large])`), Titel «COMPLETE MISSING TAGS» in `accent`, Schliessen-X.
- Zwei Auswahlfelder nebeneinander: TRACKS (z. B. «Missing tags (4)») und CATALOG CHECK.
- Pro Datei eine Karte: Dateiname (monospaced), Status-Punkt (grün = sicher, `accent` = Konflikt).
  Pro Feld: Checkbox, Label, Quellen-Badge (Folder pattern / Discogs), Wert darunter in eigenem Feld.
  Album, Label und Year teilen sich eine Zeile. Konflikt: Karte mit `accent`-Rahmen, Hinweis «OVERWRITES»,
  Checkbox standardmässig aus.
- Fusszeile: «HIGH CONFIDENCE» und «CLEAR» (Rahmen), darunter «START» (Rahmen `accent`) und
  «APPLY n FIELDS» (gefüllt `accent`), Zusammenfassung «4 TRACKS · 13 FIELDS».
- Logik unverändert aus dem bestehenden `MetadataFixStore`; nur Darstellung.

## Abnahme
- Screenshots iPhone (Simulator, 6.1") für Player, Library, Complete Tags nach `docs/screenshots/ios/`.
- Kein horizontales Scrollen, keine abgeschnittenen Zahlen bei BPM 178.9 / Key 10B / REMAIN -12:34.
