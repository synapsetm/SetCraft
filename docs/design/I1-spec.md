# iOS-Redesign I1 · Amber / Systemschrift (Gegenstück zu B6)

Referenz-Mockups: `docs/design/ios-amber/` (`player.html`, `library.html`, `complete-tags.html`,
im Browser öffnen, interaktiv). Icons dort sind Tabler-Icons — in der App **SF Symbols**.
Stilvorlage: Mac-Redesign B6 (`docs/design/B6-spec.md`, `docs/screenshots/mac/main.png`).

Tokens: `Theme.swift` (Farben, Schrift, Masse), gemeinsam für beide Targets. Keine Hex-Werte direkt in Views.

## Spielregeln
- **Keine Funktion geht verloren.** Jeder Eintrag im Funktionsinventar unten ist nach dem Redesign
  noch erreichbar — am selben oder einem in dieser Spec genannten neuen Ort. Wer etwas verschiebt,
  hakt es im Inventar ab. Was die Spec nicht ausdrücklich verschiebt, bleibt, wo es ist.
- **Nur Darstellung.** Keine Änderungen an `LibraryStore`, `PlayerStore`, `MetadataFixStore`,
  `NowPlayingManager`, Analyse, Tag-Schreiben oder SetCraftCore-Logik.
  Ausnahme: reine Anzeige-Helper (formatierte Strings, Zoom-Umrechnung, View-seitiger Filter) in der View-Schicht.
- Berechnete Werte (gespielter Key/BPM) werden **nie** persistiert (SPEC §5b).
- App ist dunkel: `.preferredColorScheme(.dark)` (heute schon in `SetCraft_iOSApp.swift`).
- Ziffern immer `.monospacedDigit()` auf SF Pro, kein `design: .monospaced`
  (Ausnahme: Dateinamen im Complete-Tags-Sheet und Pfade in `TrackInfoSheet`).
- Camelot-Farben unverändert aus `CamelotKey.color`; Tilde-Farbe aus `Theme.Palette.keyAmbiguous`
  (ersetzt `KeyChipView.ambiguousColor` und den Inline-Wert in `TrackRowView`).
- Labels in Grossbuchstaben mit Tracking über `themeLabel()`.
- Touch-Ziele mindestens 44 × 44 pt.
- Texte englisch im Code, Übersetzung in `SetCraft iOS/Localizable.xcstrings` im selben Commit;
  danach `python3 scripts/check-localization.py --target ios`. Geänderte Schreibweisen
  (z. B. Grossbuchstaben) über `.textCase(.uppercase)` statt neuer Keys, damit bestehende
  Übersetzungen weiter greifen.
- Das Mac-Target ändert sich nur durch das Verschieben von `Theme.swift` (siehe Schritt 1).

## Theme für beide Targets
- Das Projekt nutzt synchronisierte Ordner (`PBXFileSystemSynchronizedRootGroup`); eine einzelne Datei
  per Target Membership zu teilen braucht einen Exception-Eintrag in `project.pbxproj` und ist fehleranfällig.
- **Entscheid:** neuer Ordner `Shared/` als dritte synchronisierte Gruppe, Mitglied in beiden App-Targets.
  `Theme.swift` zieht dorthin (`git mv`), Inhalt unverändert. Es importiert nur SwiftUI.
- `Palette` gilt für beide Plattformen. `Typo` und `Metrics` sind auf den Mac abgestimmt
  (13 pt Fliesstext, 148 pt Waveform). iOS-Grössen kommen als Erweiterung
  `Theme.TypoIOS` / `Theme.MetricsIOS` in `SetCraft iOS/Theme+iOS.swift` — nicht die Mac-Werte ändern.
- Nicht duplizieren: keine zweite Kopie der Palette im iOS-Target.

## Funktionsinventar (Stand vor I1) — muss vollständig erhalten bleiben

### App / Navigation
| Funktion | heute | nach I1 |
|---|---|---|
| Tabs Library + Player | `TabView` in `ContentView` | gleich, aktiver Tab `accent` |
| Mini-Player → Tippen wechselt auf Player-Tab | `MiniPlayerView` | gleich |
| Mini-Player Play/Pause | `MiniPlayerView` | gleich (`accent`-Quadrat) |
| Lock Screen / Control Center (Play, Pause, Prev, Next, Scrub, Artwork) | `NowPlayingManager` | unverändert, keine UI |

### Library
| Funktion | heute | nach I1 |
|---|---|---|
| Master-BPM ein/aus, Slider, −/+ | `MasterTempoBar` (oben, `safeAreaInset`) | bleibt oben unter der Quellenzeile, nur restylt |
| Sortierung (alle `SortField`s, Häkchen bei aktivem) | Toolbar-Menü «Sort by» | `•••`-Menü «Sort by»; Kopfzeile zeigt aktive Sortierung |
| Quelle wählen | Toolbar-Menü «Sources» | Quellen-Menü (Quellenzeile) |
| Quelle entfernen | Toolbar-Menü «Remove» | Quellen-Menü, Papierkorb je Quelle |
| Ordner hinzufügen (`fileImporter`) | Menü + Leerzustand «Open folder…» | Quellen-Menü «Add folder…» + Leerzustand |
| Analyze all (mit DJ-Mix-Rückfrage) | Toolbar-Menü | `•••`-Menü «Analyze all» |
| Complete tags (mit Anzahl fehlender) | Toolbar-Menü | `•••`-Menü, Anzahl bleibt sichtbar |
| Reset play counts (mit Rückfrage) | Toolbar-Menü | `•••`-Menü, Rückfrage unverändert |
| Status «n tracks · scanning…» | Toolbar-Mitte | Quellenzeile rechts («105 TRACKS» bzw. «SCANNING…») |
| Pull-to-refresh | `.refreshable` | gleich |
| Track antippen = laden | Zeile | gleich |
| Swipe rechts: Info, Edit | `.swipeActions(.leading)` | gleich, restylt |
| Swipe links: Delete (Papierkorb → ggf. zweite Rückfrage «endgültig») | `.swipeActions(.trailing)` | gleich, Rückfragen unverändert |
| Swipe links: Analyze (mit DJ-Mix-Rückfrage) | `.swipeActions(.trailing)` | gleich, `accent`-Hintergrund, `onAccent`-Schrift |
| Zeile: Lade-Spinner, ▶/❚❚ beim laufenden Track | `TrackRowView` | gleich, laufender Titel `accent` |
| Zeile: Analyse-Spinner | `TrackRowView` | gleich |
| Zeile: Play-Count | `TrackRowView` | bleibt (klein, `textMuted`) |
| Zeile: gespielter Key mit Shift `8A → 9A` und Tilde | `TrackRowView`/`KeyBadgeView` | gleich |
| Zeile: Sterne | `StarStripView` | gleich |
| Fehlerzeile (`lastError`) | Listenkopf, rot | bleibt, Farbe `issueText` |
| Leerzustände: keine Quelle, lädt, keine Tracks | `ContentUnavailableView` | bleiben, restylt |

### Player
| Funktion | heute | nach I1 |
|---|---|---|
| Waveform scrubben | `WaveformCanvasView` DragGesture | gleich |
| Pinch-Zoom | MagnifyGesture | gleich, rastet auf Taktstufen ein |
| Zoom-Buttons −/+ | Overlay | Kapsel `−  8 BARS  +` |
| Doppeltipp = Zoom zurücksetzen | TapGesture(count: 2) | gleich, auf Standard 8 bars |
| Fortschrittsbalken | oben in der Waveform | gleich |
| Zeit elapsed / remain / Dauer | Overlay oben | ELAPSED links, REMAIN rechts (Dauer im `TrackInfoSheet`) |
| Lade-Fortschritt Netz-Quelle (`loadProgress`) | Waveform-Overlay | gleich |
| Querformat: vertikale Waveform links, Steuerung rechts | `landscapeBody` | bleibt, restylt (Mockup zeigt nur Hochformat) |
| Swipe auf Info/Steuerung = Next/Previous | `trackSwipeGesture` | gleich, nicht auf der Waveform |
| Prev / Play-Pause / Next | Transport | gleich, neue Form |
| BPM antippen → `TempoSheet` (Target BPM, ±8 %, Master tempo, Reset 100 %) | `BPMChipView` | BPM-Kachel |
| Gespielter Key mit Shift/Tilde, Analyse-Spinner | `KeyChipView` | KEY-Kachel |
| Edit → `TagEditSheet` (alle Felder, BPM ÷2/×2/÷1.5/×1.5, Key, Rating, Kommentar) | `PlayerEditButton` | `•••`-Menü der Kopfzeile: «Edit», «Info» |
| Rating setzen, gleichen Stern erneut = 0 | `BigStarsView` | gleich |
| Fehlerzeile (`lastError`) | unter der Steuerung | bleibt, `issueText` |

### Complete Tags (`MetadataFixSheet`)
| Funktion | nach I1 |
|---|---|
| Scope-Picker TRACKS, Policy-Picker CATALOG CHECK | gleich, nebeneinander |
| Discogs-Optionen (Token im Keychain, Felder-Auswahl, Hinweistexte) | bleiben, aufklappbar |
| Fortschritt «n of m», Stop, geschätzte Laufzeit | bleiben |
| Pro Feld: Checkbox, Quelle, Alternativen, «overwrites» | gleich, neue Karten-Optik |
| Select all missing · Only high confidence · Clear selection | alle drei bleiben (Mockup zeigt nur zwei) |
| Zusammenfassung «n tracks · m fields», Library-Statistik | bleiben |
| Close / Apply | Schliessen-X / «APPLY n FIELDS» |

## Navigation
- Tab-Leiste mit genau zwei Tabs: **LIBRARY** und **PLAYER**. Aktiver Tab in `accent`.
- Kein eigener Quellen-Tab: Quellen über das Quellen-Menü in der Library.

## Player (`PlayerScreen.swift`, `PlayerChips.swift`, `WaveformCanvasView.swift`) — siehe `player.html`
Reihenfolge oben → unten (Hochformat):
1. **Kopfzeile:** Cover 46 × 46 pt (`ArtworkView`, Radius 3), daneben Label TRACK, Titel (einzeilig, Ellipsis),
   Artist `textSecondary`; rechts `•••`-Menü mit **Edit** (`TagEditSheet`) und **Info** (`TrackInfoSheet`).
   Ohne Cover: `CoverPlaceholderView` in gleicher Grösse.
2. **Waveform**, Höhe ~220 pt, volle Breite, Trennlinien oben/unten `border`, Hintergrund `waveformBG`:
   - **Playhead fest in der Mitte**, `accent`, 2 pt, mit kleinem Dreieck oben. Bereich links davon abgedunkelt.
   - **Scrubben:** horizontales Ziehen verschiebt den Track unter dem Playhead.
   - **Fortschrittsbalken** 2 pt am oberen Rand (`accent`) = Position im ganzen Track.
   - **Zeit:** ELAPSED oben links, REMAIN («-» vorangestellt) oben rechts, auf halbtransparentem dunklem Hintergrund.
   - **Zoom** unten rechts: Kapsel `−  8 BARS  +` und Pinch. Stufen in Takten: 1 · 2 · 4 · 8 · 16 · 32 · 64, Standard 8.
     Pinch rastet beim Loslassen auf die nächste Stufe ein. Doppeltipp → 8.
     Umrechnung: `pointsPerSecond = width / (bars × 4 × 60 / playingBPM)` — Zoom bleibt bei Tempoänderung in Takten stabil.
     Ohne BPM: Fallback 120 BPM für die Umrechnung, Kapsel zeigt die Stufe trotzdem.
     Persistenz: neuer Key `@AppStorage("waveformZoomBars")`; der alte Key `waveformPxPerSec` wird nicht mehr gelesen.
   - **Beatgrid** (`beatgrid`): ≤ 4 bars → Linie pro Beat; ≤ 16 bars → pro Takt; darüber alle 4 Takte. Taktlinien etwas heller.
   - Gesten: Drag (Scrub) und Magnify (Zoom) wie heute über `simultaneousGesture`, so dass der Playhead
     beim Aufsetzen des zweiten Fingers nicht springt.
   - Lade-Fortschritt (`isLoadingTrack`, `loadProgress`) bleibt sichtbar.
3. **Kacheln** (2 Spalten, Trennlinie `border` dazwischen): links BPM-Label + Chevron und Wert in `accent`
   (Antippen öffnet `TempoSheet`), rechts KEY-Label und gespielter Key in Camelot-Farbe mit Shift/Tilde wie heute.
   Wert ~30 pt monospacedDigit. Während der Analyse Spinner statt Wert. **Keine** ELAPSED/REMAIN-Kacheln.
4. **Transport** (vertikal zentriert im Restraum): Previous und Next als Quadrate mit Rahmen `borderStrong`
   (56 × 46), Play/Pause als gefüllter `accent`-Block (104 × 46), Symbol `onAccent`. Radius `Metrics.radius`.
5. **Rating:** 5 Sterne, je ~32 pt, eigene Zeile, aktiv `star`, inaktiv `starDim`.
6. Fehlerzeile unter dem Rating, `issueText`.
- **Querformat:** Aufbau von `landscapeBody` bleibt (vertikale Waveform links, Kopfzeile mitte, Kacheln/Transport/Rating rechts),
  nur Tokens und Bausteine aus dem Hochformat übernehmen.
- Track-Swipe (Next/Previous) bleibt auf Kopfzeile/Kacheln/Transport, nicht auf der Waveform.

## Library (`ContentView.swift`, `TrackRowView.swift`, `MiniPlayerView.swift`, `MasterTempoBar.swift`) — siehe `library.html`
1. Oben links «SETCRAFT» (`Typo.brand`, `accent`, Tracking), rechts `•••`-Menü:
   **Sort by** (Abschnitt, Häkchen) · **Analyze all** · **Complete tags (n)** · **Reset play counts** (destruktiv).
   Bestehende Bezeichnungen und Katalog-Keys bleiben («Open folder…» wandert ins Quellen-Menü).
2. **Quellenzeile:** Nummer in `accent` («01»), Quellenname, Chevron, rechts «105 TRACKS» bzw. «SCANNING…».
   Antippen öffnet das **Quellen-Menü** (`Menu` oder Sheet): nummerierte Quellen, aktive mit `accent`-Kante,
   Papierkorb je Quelle (= «Remove» heute), darunter «Open folder…».
3. **Master-Tempo-Leiste** (`MasterTempoBar`) direkt darunter, restylt: Label MASTER BPM, Wert `accent`,
   On/Off als Rahmen-Button, Slider-Tint `accent`. Funktion unverändert.
4. **Filterfeld** + Button «ANALYZE n» (Rahmen `accent`, Text `accent`, nur sichtbar wenn n > 0;
   n = Tracks ohne BPM oder Key, Aktion = `requestAnalyze` dieser Tracks inkl. DJ-Mix-Rückfrage).
   Das Filterfeld ist **neu**: filtert nur in der View über `libraryStore.tracks` (Titel, Artist,
   Gross-/Kleinschreibung egal), kein Eingriff in den Store. Platzhalter «Filter n tracks».
5. Kopfzeile mit aktiver Sortierung, z. B. «ARTIST ↑» links und «BPM · KEY» rechts (`themeLabel()`).
6. **Zeile:** Titel (laufender Track in `accent` mit ▶/❚❚, Lade-Spinner wie heute), Artist `textSecondary`,
   kleine Sterne, Play-Count; rechts BPM (monospacedDigit, Analyse-Spinner) und Key in Camelot-Farbe
   mit Shift/Tilde. Trennlinien `rowDivider`. Keine weiteren Spalten auf dem iPhone.
7. **Swipe-Aktionen** wie heute: nach rechts Info · Edit, nach links Delete · Analyze.
   Analyze mit `accent`-Hintergrund und `onAccent`-Schrift; Delete bleibt rot (`role: .destructive`).
   Alle Rückfragen (Papierkorb, endgültig löschen, DJ-Mix) unverändert.
8. **Mini-Player** über der Tab-Leiste: Cover 34 pt, Titel, «Artist · BPM · Key», Play/Pause als `accent`-Quadrat;
   Tippen auf den Inhalt öffnet den Player-Tab.
- Leerzustände und Fehlerzeile bleiben (Texte unverändert), nur Farben aus Theme.

## Complete Tags (`SetCraft iOS/MetadataFixSheet.swift`) — siehe `complete-tags.html`
- Als **Bottom Sheet** (`.presentationDetents([.large])`), Titel «COMPLETE MISSING TAGS» in `accent`, Schliessen-X.
- Zwei Auswahlfelder nebeneinander: TRACKS (z. B. «Missing tags (4)») und CATALOG CHECK.
- Discogs-Optionen (Token, Felder, Hinweise) aufklappbar darunter, wie heute.
- Pro Datei eine Karte: Dateiname (monospaced), Status-Punkt (grün = sicher, `accent` = Konflikt).
  Pro Feld: Checkbox, Label, Quellen-Badge (Folder pattern / Discogs), Wert darunter in eigenem Feld,
  Alternativen wie heute auswählbar. Album, Label und Year teilen sich eine Zeile.
  Konflikt: Karte mit `accent`-Rahmen, Hinweis «OVERWRITES», Checkbox standardmässig aus (Logik aus dem Store).
- Fusszeile: «SELECT ALL MISSING», «HIGH CONFIDENCE», «CLEAR» (Rahmen), darunter «START» (Rahmen `accent`)
  bzw. während des Laufs Fortschritt + «STOP», und «APPLY n FIELDS» (gefüllt `accent`),
  Zusammenfassung «4 TRACKS · 13 FIELDS».
- Logik unverändert aus `MetadataFixStore`; nur Darstellung.

## Mapping auf Dateien (iOS-Target `SetCraft iOS/`)
| Bereich | Datei(en) |
|---|---|
| Tokens | `Shared/Theme.swift` (verschoben), `SetCraft iOS/Theme+iOS.swift` (neu) |
| Tabs, Library-Aufbau, Menüs, Quellen-Menü, Filter, Swipes, Rückfragen | `ContentView.swift` |
| Zeile | `TrackRowView.swift` (`StarStripView`, `KeyBadgeView`) |
| Master-Tempo | `MasterTempoBar.swift` |
| Mini-Player | `MiniPlayerView.swift` |
| Player-Aufbau, Kopfzeile, Transport, Querformat | `PlayerScreen.swift` |
| BPM-/Key-Kacheln, Sterne | `PlayerChips.swift` |
| Waveform, Zoom, Beatgrid, Zeit | `WaveformCanvasView.swift` (Darstellung, nicht die Wellenform-Daten) |
| Sheets (gleiche Tokens) | `MetadataFixSheet.swift`, `TempoSheet.swift`, `TagEditSheet.swift`, `TrackInfoSheet.swift` |
| Nur lesen | `LibraryStore.swift`, `PlayerStore.swift`, `MetadataFixStore.swift`, `NowPlayingManager.swift` |

## Vorgehen (je Schritt bauen, Mac **und** iOS kompilieren, Lokalisierung prüfen, committen)
1. `Shared/` anlegen, `Theme.swift` verschieben, beiden Targets zuordnen; `Theme+iOS.swift`.
   Mac-Build muss unverändert aussehen (kurzer Klick-Test Mac).
2. Tab-Leiste, Library-Kopf, Quellenzeile + Quellen-Menü, `•••`-Menü, Master-Tempo-Leiste.
3. Filterfeld, ANALYZE n, Sortier-Kopfzeile, Zeile, Swipe-Aktionen, Leerzustände.
4. Mini-Player.
5. Player: Kopfzeile, Kacheln, Transport, Rating (Hochformat).
6. Waveform: Playhead-Mitte, Zeit, Zoom in Takten, Beatgrid.
7. Player-Querformat.
8. Complete-Tags-Sheet, danach `TempoSheet`/`TagEditSheet`/`TrackInfoSheet` angleichen.
9. Funktionsinventar Zeile für Zeile auf dem Gerät abhaken, Screenshots, Abnahme.

## Abnahme
- Jede Zeile des Funktionsinventars auf dem iPhone ausprobiert und abgehakt.
- Screenshots iPhone (Simulator, 6.1") für Player (Hoch- und Querformat), Library, Complete Tags nach `docs/screenshots/ios/`.
- Kein horizontales Scrollen, keine abgeschnittenen Zahlen bei BPM 178.9 / Key 10B / REMAIN -12:34.
- `check-localization.py --target ios` sauber; Mac-Build unverändert.

## Offen / nicht Teil von I1
- **BPM range** stand im Entwurf als Menüpunkt. Auf iOS gibt es dafür heute keine Funktion
  (nur internes `bpmPreset` in `LibraryStore`) — wäre ein neues Feature, nicht Teil von I1.
- **CUE / KEY LOCK** gibt es auf iOS nicht; der Mac hat sie als offene Folgepunkte. Nicht Teil von I1.
