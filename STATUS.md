# STATUS — SetCraft

Laufendes Protokoll des Projektstands. Begleitend zu `CLAUDE.md` (Leitplanken)
und `SPEC.md` (vollständige Spezifikation und Phasenplan).

---

## Sitzung 2026-06-07 — Library-Reihenfolge bei Tag-Edits einfrieren, Refresh-Button, Release v1.0-8

Beim Editieren eines Tags (BPM, Titel, Rating, …) sprang der bearbeitete
Eintrag in der Mac-Library sofort an seine neue Sortier-Position — der
User verlor den visuellen Anker und musste neu suchen. Gleiches Verhalten
auf iOS, dort aber an dieser Stelle (noch) nicht angefasst. Mac-Fix:

- `LibraryViewModel.sortedTracks` (computed, hat bei jedem Render neu
  sortiert) entfernt. Stattdessen ist `tracks` selbst die Anzeige-
  Reihenfolge. Edits laufen wie bisher in-place über
  `tracks[idx] = updated` — Sortier-Index ändert sich nicht, der
  bearbeitete Eintrag bleibt stehen.
- Neue Methode `applySortOrder()` sortiert `tracks` in-place. Wird nur
  noch zu drei Zeitpunkten aufgerufen: (1) am Ende eines
  `scan`-Streams, (2) bei Spalten-Header-Klick (`LibraryView` hängt
  `.onChange(of: library.sortOrder)`), (3) beim neuen Refresh-Button.
- Neue Methode `refresh()` re-scannt die aktive Quelle (analog
  iOS-Pull-to-Refresh) — `applySortOrder` läuft am Stream-Ende
  automatisch mit.
- `nextTrack`/`previousTrack` benutzen jetzt `tracks` direkt statt
  `sortedTracks` — Player-Skip folgt damit der eingefrorenen Anzeige-
  Reihenfolge, ohne dass eine weitere Sortier-Berechnung anfällt.
- Refresh-Button in der Library-Toolbar (`arrow.triangle.2.circlepath`,
  links neben dem BPM-Preset-Menu). Deaktiviert wenn keine Quelle
  ausgewählt ist oder gerade ein Scan läuft. Strings „Refresh" /
  „Re-scan the current source and re-apply the sort order" mit DE-
  Übersetzung im Catalog.

### Manuell zu prüfen (Mac)

- Bibliothek nach BPM sortieren → BPM eines sichtbaren Tracks editieren
  → Track bleibt an seiner Position, nur die Zahl ändert sich.
- Spalten-Header klicken → komplette Liste sortiert sich neu.
- Refresh-Button → Re-Scan, am Ende ist Sortierung wiederhergestellt.

### iOS gleich nachgezogen

`LibraryStore.sortedTracks` (computed) ist weg, an seiner Stelle
`applySortOrder()` mit demselben Sort-Body, der `tracks` in-place
sortiert. Trigger: `sortField`-didSet, Pull-to-Refresh (über
`refresh()` → `selectFolder` → `scan` → completion) und Scan-Ende.
`ContentView` rendert `libraryStore.tracks`, `PlayerStore` schnappt
Queue + Fallback aus `library.tracks`. Tag-Edit am gerade in der
Liste sichtbaren Track lässt den Eintrag damit dort stehen — der
gestrige Frozen-Queue-Fix in `d0bc9a0` deckt jetzt nur noch die
Skip-Forward-Garantie ab, die sichtbare Liste ist separat eingefroren.

### Release v1.0-8 (Mac) + iOS-Build 11

Mac: `release.sh` durchgelaufen, DMG notarisiert, GitHub-Release
`v1.0-8` angelegt, Appcast in `docs/appcast.xml` aktualisiert.
Build-Nummer Mac: 7 → 8.

iOS-Build 11 ging nach TestFlight — `release-ios.sh` baute das
Archive sauber, `exportArchive` brach aber erwartungsgemäß am
Cloud-Signing-Stolperstein ab (siehe `reference-ios-testflight`).
Upload via Xcode Organizer manuell durchgeklickt.

---

## Sitzung 2026-06-05 (Abend) — iOS-Politur, Konzept-Restschuld abgearbeitet, Release v1.0-6

Drei kleine iOS-Bugs, drei „Pflicht-Bug-Fixes" aus der Konzept-Restschuld
und ein Mac- + iOS-Release. Build-Nummern: Mac 5→6, iOS 7→8→9.

### Lock-Screen zeigte falschen Play/Pause-State (`28ea587`)

`NowPlayingManager.update()` setzte nur `MPNowPlayingInfoPropertyPlaybackRate`
im Info-Dict — und iOS klebte den Lock-Screen-Button gelegentlich am
alten Zustand fest, obwohl Rate bereits auf 0 stand. Fix: explizit
`MPNowPlayingInfoCenter.default().playbackState` auf `.playing` /
`.paused` / `.stopped` setzen — das ist die maßgebliche Quelle für den
Lock-Screen-Button. Zusätzlich `MPNowPlayingInfoPropertyDefaultPlaybackRate
= 1.0` ergänzt (Tempo-Abweichungen sauber gegen Normalrate
referenzierbar). Beim Track-Ende der Playlist (`next()` ist No-op auf
dem letzten Track) ruft `engine.onPlaybackEnded` jetzt zusätzlich
`nowPlaying.update()`, damit der Stop-Zustand sicher aufs Lock-Screen
geht statt mit `playbackRate=1.0` hängenzubleiben.

### Sterne als Sortier-Kriterium (`28ea587`)

`LibraryStore.SortField` bekommt `.rating`. Sortierung absteigend (5★
zuerst, ungerated zuletzt), Tiebreak nach Titel — DJ-Workflow-Optimum
(Top-Tracks oben). „Rating" war im Strings-Catalog schon vorhanden,
`ContentView`-Picker rendert den Eintrag automatisch via
`SortField.allCases`.

### Pull-to-Refresh in der Library (`2d0028f`)

`LibraryStore.refresh()` ruft `selectFolder(id: selectedFolderID)` erneut
und awaitet auf den frischen `scanTask` — damit bleibt der iOS-Spinner,
bis der Stream durch ist. `.refreshable` an die `List` in der Library-
Screen verdrahtet. Schließt den offenen Punkt aus der Vorsitzungs-
Liste (Force-Refresh wenn extern Tracks dazukommen / verschwinden).

### WAV-Tag-Warnung (`2d0028f`)

`TagEditSheet` zeigt bei `.wav`-Dateien einen orangen Warn-Hinweis im
Form-Header („WAV-Tags werden von Serato und Rekordbox unzuverlässig
gelesen — Änderungen können in DJ-Apps unsichtbar bleiben"). Schreiben
geht weiter durch — TagLib legt ID3-RIFF-Chunks an, das funktioniert
lokal — der User weiß nur, dass DJ-Apps das Ergebnis möglicherweise
ignorieren. Minimal-Implementierung des SPEC-§8-„WAV-Sonderfall"-
Punkts, ohne den Write-Pfad zu komplizieren.

### Active-Track-Guard auf iOS jetzt aktiv (`2d0028f`)

`LibraryStore.updateTrack` ging bisher mit `force: true` durch — Edits am
laufenden Track wurden sofort geschrieben (mit der Begründung, dass
`replaceItemAt` atomar inode-swappt). Das Mac-Pattern ist
konservativer: `.fileInUse` parkt den Save in `pendingSaves`, beim
nächsten Track-Wechsel zieht `setActiveTrack` ihn nach. iOS hat den
Drain-Mechanismus jetzt auch — bisher wurde er nur für analyze()-
Ergebnisse genutzt, jetzt auch für User-Edits.

Das macht aber einen iOS-spezifischen Edge-Case auf: iOS kann die App
suspendieren oder beenden, ohne dass der Player auf einen anderen
Track wechselt — Edits könnten verloren gehen. Lösung:
`LibraryStore.flushPendingSaves()` schreibt alle geparkten Saves
zwangsmäßig (mit `force: true`) raus, und die App-Struct triggert das
via `.onChange(of: scenePhase)` bei `.background`.

### PCMLoader bricht erst bei `framesRead == 0` ab (`8f94cb7`)

Schließt einen latenten Bug, der seit Phase 3 offen stand:
`AVAudioFile.read(into:)` darf laut Apple-Doku auch mitten im Stream
weniger als `frameCapacity` Frames liefern. Die alte Abbruch-Bedingung
`framesRead < frameCapacity` konnte dadurch theoretisch mitten im
Track abbrechen — in der Praxis bei keinem getesteten Track passiert,
aber latenter Datenverlust-Pfad in BPM/Key-Analyse und Waveform-DSP.
Schließt den entsprechenden Punkt aus der Vorsitzungs-Offen-Liste.

### Release v1.0-6 (Mac) + Build 9 (iOS) (`97a6468` + `42b0100`)

Mac-Release ist live auf GitHub
(`https://github.com/synapsetm/SetCraft/releases/tag/v1.0-6`), Appcast
in `docs/appcast.xml` aktualisiert, bestehende User bekommen das
Update beim nächsten Sparkle-Check.

iOS-Build 9 für TestFlight gebaut. Cloud-Signing-Stolperstein aus
[[reference-ios-testflight]] kam **wieder** — `exportArchive` bricht
mit „Cloud signing permission error / No signing certificate iOS
Distribution found" ab. Auch nach einem erfolgreichen Build (7)
funktioniert es bei späteren Builds nicht automatisch — Distribution-
Cert scheint nicht zuverlässig in der Keychain zu landen. Workaround
weiter: Archive in Xcode Organizer öffnen, manuell „Distribute App →
Upload" klicken. **Memory-Update nötig** — der „danach sollte
automatisch durchlaufen"-Optimismus stimmt nicht.

### Manuell zu prüfen (am Gerät)

- Track laden → Pause in App → Lock-Screen aktivieren → Button muss
  Play (▶) zeigen.
- Library nach unten ziehen → Spinner, Re-Scan startet.
- WAV-Track via Library-Swipe → Edit → Warnhinweis sichtbar.
- Sterne setzen während Track läuft → App backgrounden → Stern
  persistiert über App-Resume hinweg.
- Track bis ans Ende der Playlist laufen lassen → Lock-Screen-Button
  springt auf Play (▶) statt im Pause-State zu kleben.

### Offen

- **iCloud-Sync der Library** zwischen Mac und iPhone — unverändert
  offen.
- **Cloud-Signing für iOS-TestFlight** verhält sich nicht reproduzierbar.
  Optionen für die nächste Runde: (1) API-Key-Rolle in ASC auf „Admin"
  hochstufen, (2) Distribution-Cert manuell in die Keychain
  installieren und im pbxproj/ExportOptions auf manual signing wechseln.
- **WAV-Tagging-Sonderfall** ist nur als UI-Warnung implementiert. Wer
  eine tiefere Lösung will (POPM auf WAV, separate Sidecar-DB für
  WAV-Ratings), müsste das in einer eigenen Runde tun.
- **Live-Activities** für iOS, **Crates / Playlists / Suche / History**
  cross-Plattform — alle unverändert, siehe Priorisierung von heute.

---

## Sitzung 2026-06-05 — Playhead-Sync, UI-Cleanup, Maus-Side-Buttons

### Audio↔Playhead jetzt vollständig synchron (Mac)

Der Cursor in der Waveform war minutenlang sichtbar versetzt zum hörbaren
Audio — drei unabhängige Ursachen, alle behoben:

- **`fix(core): playerNode.outputPresentationLatency statt outputNode-only`
  (`6cfd4ad`)**: `engine.outputNode.outputPresentationLatency` misst nur die
  Hardware-Buffer-Latenz (~203 ms) und lässt die TimePitch-Unit-Latenz
  (~93 ms) unter den Tisch fallen. `playerNode.outputPresentationLatency`
  summiert TimePitch + Mixer + HW korrekt — diagnostiziert mit
  `[livePos]`-Log, der die drei Latenz-Komponenten gegenübergestellt hat.

- **`fix(mac): waveform-progress auf wave-zeitachse statt player.duration`
  (`b35fbc1`)**: `liveWaveformProgress` nutzt jetzt
  `livePosition / (bins.count × secondsPerBin)`. Bei WAV ist die Differenz
  zu `player.duration` minimal (~12 ms / 460 s = 0.003 %), bei MP3/M4A mit
  ungenauer `AVAudioFile.length`-Schätzung kann sie groß werden — und dort
  driftete der Cursor exakt proportional zur Track-Position.

- **`fix(mac): waveform-spalten per float-division — playhead-drift weg`
  (`4feec34`)**: `WaveformView` aggregierte Bins per
  `bins.count / columnCount` (Integer-Division). Bei 39 620 Bins / 800 Pixel
  → 49 Bins/Spalte (real wären 49.525). Die letzten ~5 s eines 460-s-Tracks
  wurden nicht gezeichnet, der Cursor lief aber über die volle Breite —
  linearer visueller Drift, ~2 s nach 3 min. Fix: `binsPerColumnExact` als
  Double, jede Pixel-Spalte aggregiert
  `[col × binsPerColumnExact, (col+1) × binsPerColumnExact)`.

Diagnose-Methodik: drei aufeinanderfolgende Logs (`[livePos]`, `[wave]`,
`[drift]` mit Wall-Clock-Vergleich) verifizierten der Reihe nach,
dass (1) die Latenz-Korrektur 93 ms zu klein war, (2) Wave-Längen
korrekt zu Player-Duration passen und (3) `player.position` perfekt
mit Wall-Clock läuft — sprich der Drift entstand erst in der
Spalten-Verteilung. Nach den Fixes konstanter 30-ms-Offset (Render-Buffer),
kein wachsender Drift mehr.

### UI-Cleanup (Mac)

- **`feat(library): save-button raus, re-analyze zeigt spinner auch bei
  alten werten` (`1d5b16f`)**: Save-Button war redundant — `scheduleSave`
  läuft automatisch debounced, `AppDelegate` fragt beim Quit nach offenen
  Saves. Re-Analyze-Spinner: Bedingung von
  `analysisState == .scheduled && value == nil` auf `.scheduled` reduziert,
  alte Werte bleiben während der Neuberechnung sichtbar.

### Maus-Side-Buttons → Karabiner statt App-Code (`0f3e259`)

Erst versucht: `NSEvent.addLocalMonitorForEvents(matching: .systemDefined)`
mit Subtype 7 (`auxMouseButtons`), `data1` als Button-Index (1=back,
2=forward), `data2 > 0` als Down-Event. Das funktionierte technisch, kam
aber in Konflikt mit normalen UI-Klicks (Previous-Button feuerte doppelt,
Track sprang 2 zurück) — vermutlich Trackpad/Force-Touch oder Maustreiber,
der bei UI-Klicks zusätzlich systemDefined-`data1=1`-Events erzeugte.

Pragmatischer Weg: Monitor raus, statt dessen
`docs/karabiner-mouse-side-buttons.json` — Karabiner-Elements mappt
`button4` → ←, `button5` → →. Damit greifen die existierenden
`.keyboardShortcut(.leftArrow)` / `.rightArrow` ohne Event-Konflikt.

### Offen

- **iCloud-Sync der Library** zwischen Mac und iPhone — weiterhin offen
  (siehe vorigen Eintrag).
- **`PCMLoader.swift:109`** `if framesRead < Int(frameCapacity) { break }`
  ist ein latenter Bug — `AVAudioFile.read(into:)` darf laut Apple auch
  mitten im Stream weniger liefern. In der Praxis (alle bisher getesteten
  Tracks) trat es nicht auf, aber sauber wäre nur auf `framesRead == 0`
  zu prüfen.

---

## Sitzung 2026-06-04 (Nachtrag) — System-Integration & Robustheit

Die vier offenen Punkte aus dem vorigen Eintrag sind durch — die iOS-App
verhält sich jetzt wie eine native Audio-App im iOS-System.

### Lock-Screen + Control-Center + AirPods (`daf8dfb`)

`NowPlayingManager` verdrahtet den `MPRemoteCommandCenter`
(play/pause/togglePlayPause/next/previous/changePlaybackPosition)
auf die `PlayerStore`-Methoden und speist
`MPNowPlayingInfoCenter.default().nowPlayingInfo` aus
`PlayerStore.update()` (aufgerufen bei load/play/pause/seek/applyEdit).
Position + `playbackRate` werden gesetzt, System extrapoliert den
Scrubber dazwischen — keine 30-Hz-Updates. Artwork wird via
Core-`ArtworkReader` async nur bei Track-Wechsel geladen
(`lastArtworkURL`-Vergleich).

`PlayerStore.play()` und `.pause()` sind jetzt die zentralen Wege
(kapseln Engine + `nowPlaying?.update()`); `togglePlayPause` delegiert.
`weak var nowPlaying` wird vom `AppBootstrap` nach beiden Inits
gesetzt (kreuzweise Initialisierung).

### AVAudioSession-Interruption + Route-Change (`daf8dfb`)

`AudioSessionManager` beobachtet jetzt die System-Notifications:
- `interruptionNotification.began` → `onInterruptionBegan` → `pause()`.
- `interruptionNotification.ended` mit `.shouldResume` →
  `onInterruptionEndedShouldResume` → `play()`.
- `routeChangeNotification` mit `.oldDeviceUnavailable`
  (Headphones rausgezogen) → `onShouldPause` → `pause()`.

Callbacks werden im `PlayerStore`-init() verdrahtet, alle laufen
über die zentralen `play()`/`pause()`-Wege — damit gehen sie auch
sauber über `NowPlayingManager` und der Lock-Screen-Zustand bleibt
synchron.

### Re-Analyze als zweiter trailing-Swipe-Button (`25a15a3`)

`LibraryStore.analyze(trackID:force:)` bekommt einen Force-Parameter.
Der Trailing-Swipe zeigt jetzt zwei Buttons:
- **Analyze** (blau) — ergänzt nur fehlende Werte (unverändert).
- **Re-analyze** (orange, `arrow.clockwise`) — rechnet BPM und Key
  neu, übersteuert vorhandene. Pendant zum Mac-Library-Kontextmenü-
  Eintrag.

### TagLibTrackStore-Active-Guard für iOS (`c0b45eb`)

`PlayerStore.load(_:)` registriert den geladenen Track jetzt über
`LibraryStore.setActiveTrack` → `repository.setActiveTrack` im
`TagLibTrackStore`. Damit lehnt der Store Schreibvorgänge auf die
gerade im `AVAudioEngine` offene Datei mit
`StoreError.fileInUse` ab — gleiche Sicherheit wie auf dem Mac.

`LibraryStore.updateTrack` fängt `fileInUse` ab und queued den Save
in `pendingSaves: [UUID: Track]`. Beim nächsten Track-Wechsel werden
alle pendingSaves nachgeholt, deren Track jetzt nicht mehr aktiv ist —
Pendant zum Mac-`blockedByActivePlayer`-Pattern.

### Manuell verifiziert im Simulator

- Track im Player läuft, App in den Hintergrund (Home-Geste) →
  Audio läuft weiter (Background-Audio).
- Lock-Screen (`⌘⇧L`) zeigt Title/Artist/Album/Artwork +
  Play-Pause-Scrubber.
- Play/Pause vom Lock-Screen toggelt im App-Player.
- Skip-Buttons gehen durch die aktuelle Library-Sortierung.
- Scrubber-Drag im Lock-Screen löst `seek()` aus, Position synct.

### Offen

- **iCloud-Sync der Library** zwischen Mac und iPhone — würde
  `App Group` + `CloudKit`-Container brauchen (siehe
  [[project-ios-parallel]] zur Bundle-ID-Strategie).
- **Live-Activities** für die aktuelle Wiedergabe — iOS 16.1+
  Feature, nice-to-have für Lock-Screen-Anzeige ohne Now-Playing-
  Widget.
- **Force-Refresh** der Library-Liste (Pull-to-Refresh) wenn extern
  am Datei-Bestand was geändert wurde — aktuell rescannt der
  `selectFolder`-Pfad nur beim Wechsel.

---

## Sitzung 2026-06-04 — Phase 5b Schritt 2 abgeschlossen + UX-Politur, iPad-Ziel verworfen

Phase 5b Schritt 2 ist inhaltlich fertig: iOS-Library und iOS-Player
matchen die Mockups aus `docs/`, Tag-Writes laufen durch den
gleichen `TagLibTrackStore`-Pfad wie auf dem Mac. Dazu eine Runde
UX-Politur (Pinch-Zoom, Tag-Edit/Info-Sheets, Library-Sortierung)
und eine reproduzierbare Test-Strecke für den Simulator.

### iPad-Ziel verworfen — iPhone-only

`TARGETED_DEVICE_FAMILY` von `1,2` (iPhone + iPad) auf `1` (nur
iPhone) reduziert. Begründung: Die SetCraft-DJ-Workflows orientieren
sich am Daumen-One-Hand-Modell und am im Mockup gewählten 306×612-
Phone-Frame. iPad-spezifische Mehrwerte (NavigationSplitView,
breitere Waveform) wären eine eigene Layout-Linie und wurden nicht
gepflegt. CLAUDE.md, README.md und SPEC.md entsprechend angepasst —
„iOS/iPad" → „iOS (iPhone)".

### Phase 5b.2.d — Track-Liste mit Swipe-Analyze (Commits `c7e7125`, `4be423c`)

- **Camelot-Color-Extension** aus dem Mac-Target nach Core gezogen
  (`CamelotKey+Color.swift`), `var color` jetzt `public`. Wird von
  Mac und iOS gemeinsam genutzt (Variante c aus
  [[project-ios-ui-strategy]]).
- **TrackRowView** mit Play-Indikator, Titel + Artist + 5 Sterne,
  BPM (Mono) + Camelot-Badge in Modus-Farbe. Aktiver Track bekommt
  linke orange Akzentlinie + leicht warmen Hintergrund.
- **Swipe-Left** → blauer „Analyze"-Button (Wand-Icon). Tap
  → `LibraryStore.analyze(trackID:)` → AnalysisCoordinator füllt
  fehlende BPM/Key, Resultat geht über `LibraryRepository.save` in
  Datei + DB-Cache.
- **Dark Mode** als Default für die iOS-App, damit Camelot-Farben
  gegen dunklen Background wirken.

### Files-App-Integration + sc-push-Workflow (`b8a0f1d`, `092db5d`, `36b67e4`)

iOS-Simulator hat ein Henne-Ei-Problem für Test-Tracks: drag-drop
landet im „open with"-Pfad, iCloud-Drive-Login im Simulator hängt
oft im endlosen „loading". Lösung: SetCraft iOS exponiert seinen
eigenen `Documents`-Ordner über `LSSupportsOpeningDocumentsInPlace`
+ `UIFileSharingEnabled` in der Files-App.

- `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` als Auto-Setting
  reicht; `INFOPLIST_KEY_UIFileSharingEnabled` wird von Xcode beim
  Auto-Generate stillschweigend verworfen — Fix mit einer
  dedizierten `SetCraft-iOS-Info.plist` im Repo-Root, die Xcode mit
  den Auto-Keys mergt.
- `scripts/sc-push.sh` kopiert einen Ordner via
  `xcrun simctl get_app_container booted ch.buehler.beat.SetCraft.iOS data`
  in das Sandbox-Documents des gerade gebooteten Simulators. UUID
  wird bei jedem Aufruf frisch geholt — robust gegen die UUID-Wechsel
  bei Xcode-Reinstalls.

### Phase 5b.2.e1 — Player-Infrastruktur + AVAudioSession (`c62455d`)

- **AudioSessionManager** aktiviert `.playback` idempotent vor dem
  ersten Sound. iOS-only; Mac braucht das nicht.
- **PlayerStore** (`@Observable @MainActor`) besitzt einen
  `AVAudioEnginePlayer` aus Core und kennt die `LibraryStore`-
  Trackliste für Prev/Next.
- **PlayerScreen**: Track-Header mit Cover-Placeholder, Skip-Back /
  großer Play-Pause-Circle in Orange / Skip-Forward, Zeit-Anzeige
  „M:SS / -M:SS".
- **MiniPlayerView** über der Tab-Bar, Tap auf den Inhalt schaltet
  Tab-Selection auf den Player, Play-Button rechts togglet inline.
- `UIBackgroundModes = audio` in der Info.plist — Wiedergabe läuft
  beim Wechsel in eine andere App oder gesperrten Bildschirm weiter.

### Phase 5b.2.e2 — RGB-Waveform-Canvas mit Center-Playhead (`1060869`)

iOS-Player nutzt einen festen Center-Playhead, die Wellenform scrollt
unter ihm hindurch (CDJ-Stil) — im Gegensatz zum Mac mit beweglichem
Playhead über fixer Wellenform.

- Pro Pixelspalte ein Bin nachschlagen via
  `leftTime + x/pxPerSec`. pxPerSec = 52 als Default.
- Säulenhöhe ~ `pow(rms, 0.6) × 44%`, additive RGB-Farbe mit `pow(0.4)`
  Gamma auf Bass/Mitten/Höhen — wie der Mac-Renderer.
- Beat-Grid alle 4 Beats nur bei bekanntem BPM.
- Played-Side links der Mitte mit 42% Schwarz überlagert, Center-
  Playhead als weiße 2-pt Linie mit Dreieck-Markern oben/unten.
- **Drag-Scrub**: Finger links = Zeit vorwärts (natürliche Wave-
  Bewegung). `playerStore.seek(to:)` auf jedem Drag-Update —
  `AVAudioEnginePlayer` reschedulet günstig.
- **Waveform-Loading** im PlayerStore: `WaveformCache.waveform(for:)`
  awaitet aus dem Cache (Memory → SQLite → vDSP-FFT). Cancel + Race-
  Check beim schnellen Track-Wechsel.

### Phase 5b.2.e3 — Chips, Sterne, Artwork (`1cd1225`)

- **ArtworkView**: async-Load via Core-`ArtworkReader`, Fallback auf
  `CoverPlaceholderView` (lila Gradient + Vinyl-Icon). 46-pt im
  Player-Header, 34-pt im Mini-Player.
- **BPMChipView** + **KeyChipView** im Mockup-Stil.
- **BigStarsView**: fünf 32-pt Sterne, Tap auf den aktuellen Wert
  setzt das Rating zurück (Toggle-Off).
- Persistenz-Pfad: `PlayerStore.setRating(_:)` /
  `PlayerStore.applyEdit(_:)` aktualisieren `currentTrack` und
  reichen via `LibraryStore.updateTrack(_:)` an
  `LibraryRepository.save` weiter — Tag-Write inkl. POPM +
  Sterne-Präfix im Comment + DB-Cache-Update.

### UX-Politur (`f0938b8`, `911bb8c`)

- **Pinch-Zoom** auf der Waveform (15…200 px/s) via `MagnifyGesture`
  + `.simultaneousGesture` mit dem Drag-Scrub. Persistent über
  `@AppStorage("waveformPxPerSec")`. HUD „X.Xs sichtbar" während der
  Geste, fadet nach Loslassen aus.
- **TagEditSheet**: Form-basiertes Edit-Dialog für alle ID-Tags
  (Title, Artist, Album, Label, Genre, Year, BPM, Key, Rating,
  Comment). BPM-Schnell-Skalierungs-Buttons (÷2/÷1.5/×1.5/×2) für
  den Triolen-Fix. Key-Picker über alle 24 Camelot-Werte + „—".
  Done disabled solange BPM oder Year nicht-leer und unparsebar
  sind.
- **TrackInfoSheet**: read-only Datei-Eigenschaften (Name, Type,
  Size mit `ByteCountFormatter`, Duration, Bitrate, komplette
  Metadata-Übersicht plus auswählbarer Datei-Pfad).
- **Library-Swipe-Right**: graues „Info" + indigoes „Edit" als
  Leading-Actions. Swipe-Left bleibt das blaue „Analyze".
- **Library-Sortierung**: neue `SortField`-Enum (Title/Artist/BPM/
  Key) in `LibraryStore` mit Picker im `•••`-Menü. Sekundär-Sort
  nach Titel; Key-Reihenfolge folgt 1A<1B<2A<2B<…<12B. Persistenz
  via UserDefaults (`librarySortField`).
- **Key-Chip im Player** ohne Background/Border — rein informativ.
  Tap auf BPM- oder Key-Chip öffnet das `TagEditSheet`, dort ist
  Key trotzdem editierbar.

### Manuell verifiziert im Simulator

- Tracks via `sc-push.sh` ins Sandbox-Documents kopiert, in der
  Files-App unter „On My iPhone → SetCraft iOS → Documents"
  sichtbar, in SetCraft pickbar.
- Library-Liste zeigt Tracks mit Tag-Werten; Swipe-Analyze füllt
  fehlende BPM/Key.
- Tap auf Zeile lädt + spielt den Track, Mini-Player erscheint.
- Player-Tab zeigt Waveform mit Beat-Grid, Drag-Scrub funktioniert,
  Pinch-Zoom skaliert.
- BPM-Chip-Tap öffnet Tag-Edit-Sheet, Done speichert nach Tag +
  Cache, Library-Row aktualisiert sich.
- Sterne setzen + zurücksetzen per Tap.

### Offen

- **AVAudioSession-Interruption-Handling** (Anruf/Siri,
  Route-Change wenn Headphones abgezogen werden) — kommt
  in der nächsten iOS-Politur-Runde.
- **MPNowPlayingInfoCenter / Lock-Screen-Controls** —
  Background-Audio läuft, aber ohne Now-Playing-Info-Update.
- **Re-Analyze als Library-Action** (Mac hat das im Library-
  Kontextmenü). Auf iOS aktuell nur Force über das BPM-Feld leeren
  + Swipe-Analyze.
- **TagLibTrackStore.setActiveTrack-Guard** wird auf iOS bewusst
  nicht genutzt — Tag-Writes auf den gerade abspielenden Track
  laufen damit ohne Schutz. Sollte ein Konflikt auftreten,
  Mac-Pattern (`blockedByActivePlayer` + Retry nach Unload)
  nachziehen.

---

## Sitzung 2026-06-03 (Abend) — Phase 5b Schritt 2 angefangen: iOS-Target

Mockups für die iOS-App zuerst entstanden (`docs/library.html`,
`docs/player.html`) als visuelle Vorlage für Library- und Player-
Screen. Daraus abgeleitet das Konzept und die ersten drei Commits
der iOS-Umsetzung.

### Architekturentscheidungen für Phase 5b.2

- **iOS- und macOS-App parallel**, kein Sequenzieren.
- **`SetCraftCore`-Logik wird nicht verdoppelt.** Core (bereits seit
  Phase 0) bleibt die einzige Quelle für Audio/Analyse/Tags/
  Persistence. iOS bekommt eigene, schlankere ViewModels (Variante
  c im Diskussionsdurchlauf): keine Master-BPM/Key-Logik, kein
  Inline-Edit, kein NSOpenPanel. Mac-`LibraryViewModel`/`PlayerViewModel`/
  `TransportViewModel`/`WaveformViewModel` bleiben unangetastet.
- **Externe Quellen über die Files-App**, inkl. NAS/SMB. Kein
  eigener SMB-Code — iOS-System übernimmt das via FileProvider,
  App sieht den Share transparent als Ordner. Bookmark-Persistenz
  läuft durch das bestehende `FolderRecord`/`DatabaseService`.
- **Waveform-Renderer auf iOS = SwiftUI Canvas** (gleicher Code-Pfad
  wie Mac, Phase 4). Metal/`MTKView` nur, falls Performance auf
  älterer iPhone-Hardware ruckelt.
- **Tag-Writes auch auf iOS ab v1.** Gleicher
  `TagLibTrackStore`-Pfad wie Mac. SMB-Atomic-Rename-Risiko bleibt
  als Edge-Case (Toast/Error-State, kein silent fail).
- **Min-iOS = 26.5** (`IPHONEOS_DEPLOYMENT_TARGET`),
  `TARGETED_DEVICE_FAMILY = 1,2` → iPhone + iPad (am 2026-06-04
  auf 1 = iPhone-only reduziert, siehe Sitzung 2026-06-04).
- **Bundle-ID `ch.buehler.beat.SetCraft.iOS`** (Variante B/Suffix mit
  Punkt). Operationale Trennung von der Sparkle-Welt des Mac, keine
  Provisioning-Konflikte, kein iCloud-Sync aktuell geplant — falls
  später nötig, via App Group `group.ch.buehler.beat.SetCraft`.

### Drei Commits

1. **`f31c23a` feat(ios): leeres app-target mit tab-bar**
   - Neues App-Target `SetCraft iOS` zum bestehenden
     `SetCraft.xcodeproj` hinzugefügt (manuell via Xcode-UI, damit
     die v1.0-3-stabile Mac-App nicht durch direkten pbxproj-Patch
     gefährdet wird).
   - SwiftUI-Skelett: `SetCraft_iOSApp` + `ContentView` mit
     `TabView(Library, Player)`. Beide Tabs sind
     `ContentUnavailableView`-Platzhalter.
   - SetCraftCore-Package per General → Frameworks ans neue Target
     verlinkt. Die in Phase 5b Schritt 1 vorbereiteten iOS-Slices
     der xcframeworks (TagLib, Aubio, KeyFinder) ziehen automatisch.

2. **`8d50d16` feat(ios): source-picker mit security-scoped bookmarks**
   - Neue Klassen im iOS-Target:
     - `AppBootstrap` (`@MainActor`): hält `DatabaseService` +
       `LibraryRepository` + `LibraryStore` über die App-Lebenszeit.
       Pendant zum `init()` der Mac-`SetCraftApp`.
     - `LibraryStore` (`@Observable @MainActor`): schlankes iOS-VM
       mit API `restoreSavedFolders`, `addFolder(url:)`,
       `selectFolder(id:)`, `removeFolder(id:)`. Wiederverwendet
       Core-`FolderRecord`/`DatabaseService` 1:1.
   - `LibraryScreen` mit `NavigationStack` + Toolbar-Menü
     (Sources-Sektion mit ✓ auf der aktiven Quelle, Remove-Sektion,
     „Open folder…").
   - Picker per `.fileImporter(allowedContentTypes: [.folder])`;
     Bookmark-Erzeugung mit `options: []` (kein `.withSecurityScope`
     — das ist macOS-only).
   - `selectFolder` öffnet/balanciert den Security-Scope, refresht
     stale Bookmarks, löscht unresolvable Einträge still.

3. **`dce251d` chore(ios): bundle-id mit punkt statt bindestrich**
   - Xcode hatte aus dem Produktnamen mit Leerzeichen automatisch
     `ch.buehler.beat.SetCraft-iOS` abgeleitet. Auf reverse-DNS-
     konsistenten Punkt umgestellt:
     `ch.buehler.beat.SetCraft.iOS`.

### Manuell verifiziert im Simulator

- App startet mit „Keine Quelle aktiv"-Leerstand.
- Picker öffnet Files-App, Ordnerauswahl funktioniert (lokal +
  iCloud Drive).
- Header zeigt Ordnername + Track-Count.
- App-Restart restored den letzten Ordner ohne neuen Picker
  → Security-Scoped Bookmarks persistieren über App-Sessions.
- Quellen-Wechsel + Quellen-Entfernen über das `•••`-Menü.
- NAS/SMB nicht im Simulator getestet (kein realer Mount-Point),
  läuft aber durch denselben `.fileImporter`-Pfad — auf echtem
  iPhone sollte es funktionieren.

### Bewusst nicht in diesem Schritt

- **AppKit-Conditionals** (waren in der Phasenplanung): unnötig —
  Core ist 100% AppKit-frei. `import AppKit` lebt nur im Mac-App-
  Target, das vom iOS-Build nicht angefasst wird.
- **`AVAudioSession`-Setup + Background-Audio-Plist-Key**: wandert
  nach 5b.2.e — ohne aktiven Player wäre die Konfiguration jetzt
  funktionslos.
- **Mac-Migration**: keine. Mac-Code unangetastet, v1.0-3 läuft
  weiter wie ist.

### Offen für Phase 5b Schritt 2

- **5b.2.d** — Library-Tab bekommt die Track-Liste aus dem Mockup
  (Titel/Artist, ★★★, BPM, Camelot-Badge, Swipe-Left-Analyze,
  Highlight des laufenden Tracks, Mini-Player über der Tab-Bar
  sobald der Player existiert).
- **5b.2.e** — Player-Tab aus dem Mockup: Center-Playhead-RGB-
  Waveform (Canvas, Drag-Scrub), Track-Header mit Cover, Transport,
  BPM-Chip + Edit-Sheet, Key-Chip + Camelot-Wheel-Picker, große
  Sterne. `AVAudioSession`-Konfiguration +
  `UIBackgroundModes = audio` dort.

---

## Sitzung 2026-06-03 (Nachzug) — Sparkle-Sandbox-Fix, Release v1.0-3

**Ausgangslage:** Auto-Update via Sparkle bricht in v1.0-1/2 mit
„An error occurred while launching the installer" ab. Konsole zeigt
`authd: Sandbox denied authorizing right 'config.add.<bundle-id>.sparkle2-auth'`
und `sandboxd: deny mach-lookup ch.buehler.beat.SetCraft-spks`. Klassisches
Sparkle-2-Sandbox-Setup-Loch — Bundle, Notarisierung, Appcast-Signatur sind
alle in Ordnung, aber der Sandbox-Trust für Sparkles XPC-Services fehlt.

**Fix gemäß** [sparkle-project.org/documentation/sandboxing](https://sparkle-project.org/documentation/sandboxing/) **(Path A):**

1. `SetCraft.entitlements`:
   - `com.apple.security.network.client` **entfernt** — die App selbst macht
     keinen Outbound-HTTPS mehr; das übernimmt Sparkles Downloader-XPC.
   - **Neu**: `com.apple.security.temporary-exception.mach-lookup.global-name`
     mit `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` und `-spki`. Xcode substituiert
     den Platzhalter beim Signieren — verifiziert per
     `codesign -d --entitlements - SetCraft.app`: liefert
     `ch.buehler.beat.SetCraft-spks` und `-spki`.
2. `Info.plist`:
   - `SUEnableInstallerLauncherService` = YES (aktiviert Installer-XPC,
     registriert `<bundle-id>-spks`).
   - `SUEnableDownloaderService` = YES (aktiviert Downloader-XPC,
     registriert `<bundle-id>-spki`).

**Bewusst NICHT gemacht** (auch wenn das Web es manchmal empfiehlt):
- Kein Kopieren der XPC-Services nach `SetCraft.app/Contents/XPCServices/`.
  Sparkles eigene Doku sagt explizit: in der Sandbox **nicht** zusätzlich
  bundlen; die Framework-XPCs reichen, sobald die Info.plist-Schalter und
  Mach-Lookup-Entitlements stehen.
- Kein Rename der XPC-Bundle-IDs. Die behalten ihre Sparkle-Namen
  (`org.sparkle-project.InstallerService` /
  `org.sparkle-project.DownloaderService`). Nur der Mach-Service-Name am
  Runtime erbt den App-Bundle-ID-Prefix.
- Kein `--deep` beim Re-Signieren im Release-Skript — laut Sparkle-Doku
  „a common source of Sandboxing errors". `release.sh` macht das bewusst
  nicht.
- Keine zusätzliche `com.apple.security.temporary-exception.authorization-right`
  für `sparkle2-auth`. Der `authd`-Sandbox-Deny ist nur Folgefehler des
  Mach-Lookup-Deny — mit korrekt aufgesetzten XPCs verschwindet er
  automatisch.

**Release v1.0-3:** `CURRENT_PROJECT_VERSION` 2→3.

**Migration für bestehende v1.0-1- und v1.0-2-User:** Auto-Update bleibt in
diesen Versionen kaputt — das Loch ist die installierte App, nicht der
Appcast. Einmaliger manueller Wechsel nötig: DMG laden, App nach
`/Applications` ziehen, ersetzen. Ab v1.0-3 läuft `Check for Updates…`
dann sauber durch die XPC-Bridge.

---

## Sitzung 2026-06-03 — Player-UX-Sprint, Decoder-Fallback, Release v1.0-2

**Build:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
-project SetCraft.xcodeproj -scheme SetCraft -destination 'platform=macOS'
-configuration Debug build` läuft sauber durch (`xcode-select` zeigt auf
CommandLineTools — `DEVELOPER_DIR`-Override umgeht das ohne `sudo`). Sieben
fachliche Bündel, alle in `main` gemerged und als `v1.0-2` releast.

### Was neu im Player ist

1. **Album-Cover links neben Titel/Artist** im Player-Header. 48×48 mit
   abgerundetem `RoundedRectangle`-Rahmen; lädt asynchron via
   `ArtworkReader.loadArtwork(url:)` über `AVAsset.commonMetadata` →
   `commonIdentifierArtwork` → `.dataValue`. Funktioniert formatübergreifend
   (MP3 APIC / M4A covr / FLAC PICTURE / Ogg) ohne TagLib-Erweiterung. Wenn
   kein Cover hinterlegt ist, bleibt der leere Rahmen sichtbar — Header-Höhe
   konstant. Tracks ohne Library-Eintrag bekommen denselben Render-Pfad,
   weil nur die URL nötig ist.
2. **Prev/Next-Buttons** ⏮ ⏯ ⏭ in der Transport-Bar, beide mit `←`/`→` als
   direkten Tastatur-Shortcut (ohne Modifier). Konflikt mit Inline-Edits ist
   keiner: SwiftUI reicht die Pfeiltasten ans fokussierte TextField durch,
   gleiche Mechanik wie das bestehende `Space` für Play/Pause.
3. **Sterne-Rating** als editierbarer Chip neben dem KeyChip, mit demselben
   `.thinMaterial`-Capsule-Outline wie der TempoChip → klares „antippbar"-
   Signal. Tap geht durch `library.setRating(forURL:_:)` und damit durch den
   gewohnten 600-ms-Debounce-Save (POPM + Sterne-Präfix im Comment via
   TagLib-Bridge). Tracks ohne Library-Eintrag dimmen den Chip auf 45 %.

### Decoder-Fallback in `PCMLoader`

Konkreter Fehler beim Öffnen mancher MP3s (z. B. „Kalki, Sonic Species - You
Are the Light"):
`AVAudioFile(forReading:)` wirft `Foundation._GenericObjCError error 0`,
obwohl `AVAudioPlayerNode` dieselbe Datei sauber abspielt — typisch für
MP3-Header, mit denen der ExtAudioFile-Decoder ein Problem hat. Fix in zwei
Stufen:

1. Versuch 1: weiterhin `AVAudioFile`-Pfad (schnell, deckt 99 % ab).
2. Bei Fehler: **`AVAssetReader`-Fallback** über `AVURLAsset` →
   `AVAssetReaderTrackOutput` mit Float32-mono-PCM in der nativen Sample-Rate
   des Audio-Tracks. CoreMedia-Decoder statt ExtAudioFile — kommt mit den
   problematischen Headern durch. Native Sample-Rate via
   `CMAudioFormatDescriptionGetStreamBasicDescription`, also kein Resampling.

`waveform.lastError` (orange) verschwand auf den Testfiles sofort. Die
ursprüngliche Retry-Krücke ist raus — sie hätte das echte Format-Problem
nicht gelöst und nur Latenz erzeugt.

### Library-Verhalten

- **Waveform-Prefetch beim Scan**: `LibraryViewModel.scan(folder:)` ruft
  `prefetchWaveform(track)` direkt im `for await`-Loop auf, sobald ein Track
  vom Scanner reinkommt. `WaveformCache` dedupliziert per URL, hält Ergebnis
  in Memory und in SQLite — kalter Scan rechnet alles im Hintergrund, warmer
  Scan kommt aus dem DB-Cache. Klick auf einen Track holt die Welle aus dem
  Cache statt synchron zu analysieren.
- **„Remove source" leert die Tabelle zuverlässig**: bisher konnten zwei
  Pfade dafür sorgen, dass Tracks nach dem Entfernen des letzten Folders
  sichtbar blieben:
  - laufender `scanTask` pumpte nach dem `tracks = []` weiter Tracks
    nach → Fix: `scanTask?.cancel()` + `isScanning = false` im
    `selectFolder(id: nil)`-Clear-Zweig.
  - `removeFolder` triggerte den Clear nur bei `selectedFolderID == id` →
    Fix: prüft stattdessen, ob die aktuelle Selektion noch auf einen
    existierenden Ordner zeigt; wenn nicht, läuft die Selektions-/Clear-
    Logik.
- **Neue Spalte „Filename"** in der Library-Tabelle (sortierbar via
  `\.fileName` auf `Track`), einsortiert in `fileInfoColumns` vor „Type".
- **Prev/Next ziehen die Library-Selektion mit** (`library.selectedTrackID
  = track.id`), damit Tabelle und Player synchron stehen.

### Quellgesteuerte Fundamente

- Neuer Reader: `SetCraftCore/Sources/SetCraftCore/Library/ArtworkReader.swift`
  — minimaler async-Wrapper um `AVAsset.commonMetadata`. Bewusst keine
  Cache-Schicht; das Bild ist klein, der Render-Pfad selten genug, und ein
  späterer Cache wäre genauso trivial nachzulegen.
- Neuer View: `SetCraft/ArtworkView.swift` mit `task(id: url)` für sauberes
  Cancel-on-URL-Change-Verhalten.
- `Track` hat jetzt `fileName: String` (analog zu bestehendem
  `fileType: String`).
- `PBXFileSystemSynchronizedRootGroup` ist aktiv, Xcode pickt neue Dateien im
  `SetCraft/`-Ordner automatisch auf — keine `pbxproj`-Patches nötig.

### Release v1.0-2

- Build-Nummer von 1 auf 2 in `pbxproj` angehoben (`MARKETING_VERSION = 1.0`,
  `CURRENT_PROJECT_VERSION = 2`). Tag `v1.0-2`, DMG `SetCraft-1.0-2.dmg`.
- `scripts/release.sh` produziert wie gewohnt notarisiertes DMG, lädt es als
  GitHub-Release-Asset hoch und schreibt den signierten Appcast auf
  `docs/appcast.xml` (GitHub Pages liefert ihn unter der `SUFeedURL` aus, die
  in `Info.plist` steht).

### Was bewusst nicht in dieser Sitzung war

- Throttling der parallelen Waveform-Prefetches. Bei riesigen Libraries
  (Tausende Tracks) würden alle Detached Tasks gleichzeitig CPU/Disk
  beanspruchen — bei `.utility`-Priorität verträglich, aber irgendwann
  spürbar. Wenn nötig: TaskGroup mit Concurrency-Limit ~3–4.
- Bordsteinaktion auf dem Player-Bild bei Track-Wechsel (Fade/Crossfade).
- Mini-Cover als Spalte in der Library-Tabelle.
- ⌘← / ⌘→ als Alternative zu blanken Pfeiltasten — bewusst weggelassen,
  weil die blanken Pfeiltasten reichen.

---

## Phase 0 — abgeschlossen (Commit `4595666`)

**Build:** `xcodebuild -scheme SetCraft -destination 'platform=macOS' build` läuft
sauber durch. Eine harmlose Info-Warnung („AppIntents.framework dependency not
found") bleibt — kein Handlungsbedarf.

**Code-Organisation:** Weg B (lokales Swift Package `SetCraftCore`) gewählt.

### Was steht

- `SetCraftCore` als lokales Swift Package im Repo, eingebunden über
  `XCLocalSwiftPackageReference` im App-Target.
- **Modelle** (plattformfrei, in `SetCraftCore`):
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
    Finder-„Öffnen mit SetCraft" (`Info.plist` mit `CFBundleDocumentTypes`
    für `public.audio`, `public.mp3`, `public.mpeg-4-audio`,
    `com.apple.m4a-audio`, `com.apple.coreaudio-format`, `org.xiph.flac`,
    `com.microsoft.waveform-audio`, `public.aifc-audio`, `public.aiff-audio`,
    plus `.onOpenURL` in `SetCraftApp`).
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
  `.mm`-Brücke in `SetCraftCore/Sources/SetCraftCore/Bridge/` mit reinem
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

**Build:** `xcodebuild -project SetCraft.xcodeproj -scheme SetCraft -destination
'platform=macOS' build` läuft sauber durch.
**Tests:** `swift test` im `SetCraftCore`-Paket, 16/16 grün
(`RatingPrefixTests`).

### Entscheidungen aus dem Start von Phase 1

- **Sandbox** wurde sofort auf `readwrite` umgestellt, plus
  `files.bookmarks.app-scope` (für persistente Library-Ordner in Phase 5).
  Eigene `SetCraft/SetCraft.entitlements`-Datei als alleinige Quelle der Wahrheit;
  `ENABLE_USER_SELECTED_FILES` aus den Build-Settings entfernt.
- **TagLib** wird via `Vendor/TagLib/build-taglib.sh` reproduzierbar als
  universelles macOS-`.xcframework` (arm64 + x86_64) gebaut und liegt in
  `SetCraftCore/Vendor/TagLib.xcframework`. CMake ist Build-Voraussetzung
  (`brew install cmake`).
- **Rating-Kommentar-Token-Format:** `★★★★☆ | <rest>` (menschenlesbar in
  Serato und Rekordbox). Implementiert in `RatingPrefix.parse/format`, mit
  16 Unit-Tests inkl. Round-Trip, Umlauten und Emoji.

### Was steht

- **`SetCraftCore`** mit drei Targets in `Package.swift`:
  - `TagLib` (binaryTarget, statisches `.xcframework`)
  - `SetCraftCoreObjC` (Objective-C++-Brücke `SetCraftTagBridge`)
  - `SetCraftCore` (reines Swift) und `SetCraftCoreTests`.
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

**Build:** `xcodebuild -project SetCraft.xcodeproj -scheme SetCraft -destination
'platform=macOS' build` läuft sauber durch.
**Tests:** `swift test` im `SetCraftCore`-Paket, 29/29 grün
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

**Build:** `xcodebuild -project SetCraft.xcodeproj -scheme SetCraft -destination
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
- **Bridge** (`SetCraftAnalyzerBridge.mm`): nimmt mono Float32-PCM von
  Swift entgegen und ruft aubio (Tempo-Tracking, win 1024 / hop 512)
  bzw. libKeyFinder; key_t → Camelot-Notation.
- **Swift-Layer** in `SetCraftCore/Analysis/`: `PCMLoader` (AVAudioFile →
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

**Build:** `xcodebuild -project SetCraft.xcodeproj -scheme SetCraft -destination
'platform=macOS' build` läuft sauber durch.
**Tests:** `swift test` im `SetCraftCore`-Paket, 36/36 grün (3 neue
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

- **GRDB.swift 7.x** als SPM-Dep in `SetCraftCore`. `DatabaseService`
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

## Phase 5b — angefangen, Schritt 1/2

### Schritt 1 — abgeschlossen: xcframeworks um iOS-Slices erweitern

Alle drei Vendor-`.xcframework`s tragen jetzt **drei** Plattform-Slices
(`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`). Damit
ist `SetCraftCore`-`Package.swift` auf iOS auflösbar — der eigentliche
iOS-App-Code folgt im nächsten Schritt.

- `Vendor/TagLib/build-taglib.sh`: `build_taglib_variant()`-Funktion
  baut pro Plattform mit den passenden `CMAKE_OSX_*`-Flags. Echo-
  Statements nach stderr verschoben, damit `$(…)` nur den Pfad
  einfängt. `3rdparty/utfcpp` wird aus dem entpackten utfcpp-Quellbaum
  bestückt (im Tarball ist's eine leere Submodul-Hülle).
- `Vendor/aubio/build-aubio.sh`: `build_aubio_variant()` cross-
  compiliert via `CFLAGS/LDFLAGS` auf `iphoneos`/`iphonesimulator`-SDK
  + `mios-version-min`. Configure-Tests laufen weiter; einige
  Runtime-Checks der iOS-Simulator-Binaries schlagen fehl, sind aber
  für die statische Lib irrelevant.
- `Vendor/KeyFinder/build-keyfinder.sh`: `build_combined_variant()`
  baut fftw3 und libKeyFinder pro Plattform und mergt sie via
  `libtool`. libKeyFinders mitgeliefertes `FindFFTW3.cmake` honoriert
  `FFTW3_ROOT` unter der iOS-Toolchain nicht — wir setzen jetzt
  zusätzlich `FFTW3_LIBRARY` und `FFTW3_INCLUDE_DIR` explizit.

Repo-Größe der Vendor-Binaries danach: TagLib 13 MB, KeyFinder 8 MB,
aubio 5 MB. macOS-Build und 36 Tests unverändert grün.

### Schritt 2 — offen: iOS-App-Code

Für die nächste Sitzung:

- iOS-Target im Xcode-Projekt anlegen.
- AppKit-Code mit `#if os(macOS)` kapseln (`AppDelegate`,
  `NSOpenPanel` in `PlayerViewModel`/`LibraryViewModel`,
  `NSApplicationDelegateAdaptor`).
- `DocumentPicker` als iOS-Pendant für Datei- und Ordnerwahl.
- `AVAudioSession` für iOS konfigurieren (Category playback,
  Background-Audio, Interruption-Handling).
- ColorScheme- und Appearance-Toggle bleiben SwiftUI-übergreifend.

---

## Phase 5c — optional (SFBAudioEngine)

- Ogg Vorbis / WavPack / Monkey's Audio-Unterstützung via
  SFBAudioEngine. Erst einziehen, wenn die Library es verlangt.

---

## Stand am Sitzungsende (Commit `65c1e17`)

- **Phasen 0–5a komplett**, Phase 5b ist auf Build-Infrastruktur-
  Ebene vorbereitet (iOS-xcframeworks vorhanden).
- **Tests:** 36/36 grün (`swift test` im `SetCraftCore`-Paket).
- **macOS-Build:** `xcodebuild -project SetCraft.xcodeproj -scheme SetCraft
  -destination 'platform=macOS' build` läuft sauber.
- **Repo:** sauber lokal und auf
  https://github.com/synapsetm/SetCraft
  (`main` ist mit `origin/main` synchron).

### Was die App heute kann

- Library-Sidebar mit mehreren persistenten Quellen (Security-Scoped
  Bookmarks). Beim Start wird die zuletzt aktive Quelle automatisch
  wiederhergestellt.
- SQLite-Cache (GRDB) für Track-Metadaten und Waveforms. Datei =
  Quelle der Wahrheit; Cache invalidiert sich über `mtime`.
- Library-Tabelle: sortierbar, Spalten ein-/ausblendbar und
  reorderbar (per `TableColumnCustomization`, persistiert), inkl.
  Kommentar-Spalte. Inline-Edit für Text-Spalten und BPM.
- Rote-Punkt-Indikator pro Track mit ungespeicherten Änderungen;
  automatisches Nachholen bei aktiver Player-Datei; manueller
  ⌘S-Befehl; Quit-Dialog (Speichern / Verwerfen / Abbrechen).
- Player: Datei-öffnen-/Cue-/Play-Pause-/Entladen-Toolbar.
  Position-Slider wurde entfernt — gesucht wird über die Waveform
  (Tap = Seek).
- Tempo- und Key-Chips mit Master-Logik (Modus A, Mode-Mismatch wird
  signalisiert), Key-Lock-Toggle, Tempo-Slider ±8 %.
- Auto-Analyse beim Track-Load (aubio BPM + libKeyFinder Key) inkl.
  BPM-Range-Preset und Batch-Button „Fehlende analysieren". Resultate
  fliessen direkt zurück in die Datei-Tags und in den Player-Chip.
- RGB-Waveform: vDSP-FFT, drei Bänder (Bass < 200 Hz / Mitten /
  Höhen > 2 kHz), Light/Dark-adaptiver Hintergrund, perzeptuelle
  Helligkeit, Cue-Marker und Playhead.
- Manuelle Erscheinungsbild-Wahl (System / Hell / Dunkel) über das
  „Ansicht"-Menü.

### Was noch ansteht

- **Phase 5b Schritt 2** (siehe oben): iOS-Target + DocumentPicker +
  AVAudioSession + AppKit-Conditionals.
- **Phase 5c**: SFBAudioEngine, wenn Ogg Vorbis / WavPack benötigt
  werden.
- **Folge-Phasen**: Crates / Playlists / History (SQLite-Basis steht),
  Beat-Marker auf der Waveform, Metal-Renderer für die Waveform,
  Settings-UI für Defaults.

### Manuelle Tests, die nach 5a noch sinnvoll sind

- Ordner als Quelle hinzufügen → App schliessen → wieder öffnen →
  Quelle wird automatisch gescannt (Bookmark wurde resolved, Cache
  liefert die Tracks schnell).
- Track inline editieren, Quit auslösen → Dialog erscheint,
  „Speichern" hält die Beendigung bis zum Abschluss zurück.
- Auf einem zweiten Lauf der Library: Waveform erscheint praktisch
  sofort, weil die Bins aus der DB kommen.

---

## Sitzung 2026-06-01 — UI-Politur und Lokalisierung

Eine zusammenhängende UI-Runde, ohne neue Phase. Keine Tests gebrochen
(`swift build` im Package und `xcodebuild ... -destination 'platform=macOS'`
sind grün).

### Branding & Assets

- **App-Icon eingesetzt.** Render-Skript (`docs/icon/render_icons.py`,
  Pillow) erzeugt die zehn macOS-Größen 16…1024 plus ein 1024-Master für
  den iOS-Slot. Die PNGs liegen im `AppIcon.appiconset`, `Contents.json`
  trägt alle mac- und iOS-Slots inkl. light/dark/tinted. `Assets.car`
  führt nachweislich alle Größen (`assetutil --info`); die kompakte
  `AppIcon.icns` (nur 16/32/128/256) ist gewollt — macOS zieht hochauf-
  lösende Varianten zur Laufzeit aus dem Asset Catalog. Wenn der Finder
  weiterhin ein altes Icon zeigt, ist es **immer** der Icon Services
  Cache (`sudo rm -rf /Library/Caches/com.apple.iconservices.store;
  killall Dock Finder`).

### Player

- **Transport-Bar neu sortiert:** Open file → Load → Play/Pause →
  Unload. Der neue Load-Button lädt den in der Library markierten
  Track in den Player. Play/Pause nutzt jetzt `playpause.fill` als
  Symbol — eindeutig, egal in welchem Zustand.
- **Cue-Funktion komplett raus** (Button, ViewModel, `AudioEngine`-
  Protokoll, Cue-Marker auf der Waveform).
- **Key-Editierung entfernt.** Der `KeyChip` ist jetzt ein reines
  Label (kein Capsule-Hintergrund, keine Border), damit visuell klar
  wird: hier ist nichts antippbar. Master-Key-State,
  `setKey`/`nudgeSemitone`/`setIsGlobalKey` und der Mode-Mismatch-
  Indikator sind aus `TransportViewModel` raus.
- **Key-Lock-Toggle entfernt.** Schloss-Symbol existierte als Knopf,
  hatte aber faktisch keine Wirkung (`AVAudioUnitTimePitch`
  entkoppelt Rate und Pitch ohnehin, das Flag war „always on"). Mit
  dem Schalter raus auch die `keyLock`-Property auf `AudioEngine`-
  Protokoll und `AVAudioEnginePlayer`.
- **`TempoChip` signalisiert Editierbarkeit deutlicher.** Behält
  Capsule + Border, hat jetzt ein `chevron.down` rechts und tauscht
  beim Hover den Cursor auf `pointingHand`. Differenziert sich klar
  vom (read-only) `KeyChip`.
- **Camelot-Farben im Player-Chip und in der Library-Key-Spalte.**
  `CamelotKey.color` (in `SetCraft/CamelotKeyColor.swift`) bildet
  Position 1–12 auf ein Hue-Wheel ab; Moll (A) ist satter/dunkler,
  Dur (B) heller. Konvention orientiert sich an DJ-Apps.
- **Player-Header zeigt Artist & Titel** (statt nur den Dateinamen).
  Titel kommt aus den Tags via Library-Lookup; Fallback ist der
  Dateiname ohne Endung. Untertitel ist der Artist; Fallback
  „Unknown artist".

### Library

- **Neue Spalten:** Album, Label, Year, Type, Bitrate, Size. Album
  und Label sind editierbar; Year, Bitrate, Size kommen read-only
  aus den Tags + `FileManager`. Da der SwiftUI-`Table`-Builder bei
  ≈10 Spalten dichtmacht, sind die Spalten in vier
  `@TableColumnBuilder`-Gruppen (`primaryColumns`,
  `metadataColumns`, `fileInfoColumns`, `tailColumns`) aufgeteilt.
- **`Track` erweitert** um `year`, `bitrate`, `label`, `fileSize`
  plus `fileType` (computed aus URL-Extension). `SetCraftTagBridge`
  liest/schreibt LABEL (Fallback PUBLISHER) via PropertyMap.
- **Cache-Migration v2** ergänzt die Spalten in der SQLite-Tabelle.
  **Migration v3** leert die `tracks`-Tabelle einmalig, damit alte
  Cache-Zeilen ohne year/bitrate/file_size beim nächsten Scan aus
  den Tags neu befüllt werden.
- **Drag & Drop integriert in die Library.** Wird eine Datei in den
  Player gezogen, prüft `LibraryViewModel.handleDroppedFile(_:)`:
  - Ist der Eltern-Ordner schon Quelle → Sidebar schaltet darauf um.
  - Ist er unbekannt → `NSOpenPanel` öffnet sich pre-positioned auf
    den Ordner, der User bestätigt einmalig (sandbox-bedingt, damit
    das Security-Scoped Bookmark sauber registriert wird), danach
    persistAndScan.

### Lokalisierung

- **Komplette App auf Englisch übersetzt**, deutsche Übersetzungen
  in `SetCraft/Localizable.xcstrings`. `developmentRegion = en`,
  `knownRegions` enthält jetzt zusätzlich `de`. System mit DE-
  Sprache zeigt deutsch, alle anderen Englisch.

### Erscheinungsbild — Bugfix

- **Light/Dark/System-Schalter wirkt zuverlässig.** `.preferred-
  ColorScheme(.dark) → .preferredColorScheme(nil)` ließ auf macOS
  `List`, `Table` und `Canvas` im dunklen Zustand hängen (Sidebar
  und Library-Tabelle blieben schwarz, obwohl der Player-Bereich
  schon hell war). Fix:
  - `.preferredColorScheme(...)` entfernt — kein SwiftUI-Modifier
    mehr für das Schema.
  - `NSApplication.shared.appearance` ist die einzige Wahrheits-
    quelle, gesetzt in `SetCraftApp.init()` (vor dem ersten Window)
    und per `.onChange(of: appearanceRaw)`.
  - Zusätzlich wird `appearance` auf **jedem** existierenden
    Window gesetzt, weil ein Window, das einmal explizit
    `.darkAqua` zugewiesen bekam, sonst auf diesem Wert hängen
    bleibt.
- **Hardcoded `.white`** im Waveform-Loading-Overlay durch
  `.primary.opacity(0.85)` ersetzt — sonst stand der Text im
  Light-Mode unsichtbar auf weißem Hintergrund.

### Architektur-Notiz

- Es entstand kein zweites Modell für „Track in der Library, aber
  ohne Source". Wir bleiben bei der Regel „jeder sichtbare Track
  gehört zu einer Folder-Source". Drag-and-Drop zwingt deshalb in
  den Pfad „Source hinzufügen", was zwar einen Picker-Klick
  kostet, aber das Sandbox- und Bookmark-Modell konsistent hält.

### Manuelle Tests, die jetzt sinnvoll sind

- App im Light-Mode starten → manuell auf Dark schalten → auf
  System zurück → alle Bereiche (Player, Waveform, Sidebar,
  Tabelle) wechseln synchron.
- Track aus Finder in den Player ziehen, dessen Ordner noch keine
  Quelle ist → `NSOpenPanel` poppt vorausgewählt auf, nach
  „Add as source" erscheint der Track in der Liste.
- Sprach-Setting auf Deutsch → App-Texte in Deutsch; System auf
  Englisch → englische Texte (ohne neu zu kompilieren).
- Library mit altem Cache öffnen → einmaliger v3-Wipe lässt
  Year/Bitrate/Size beim Re-Scan auftauchen.

---

## Distribution-Setup (2026-06-01)

App ist vorbereitet, um **außerhalb des App Stores** als notarisiertes,
selbst-aktualisierendes DMG verteilt zu werden.

### Im Repo

- **Sparkle 2.x** als `XCRemoteSwiftPackageReference` ins Xcode-Projekt
  eingebunden (`https://github.com/sparkle-project/Sparkle`, minor-stable
  ab 2.6.0).
- `SetCraft/UpdaterController.swift` kapselt
  `SPUStandardUpdaterController`; `SetCraftApp` hält den Updater als
  `@State` über die App-Lebenszeit und ergänzt einen Menüpunkt
  „SetCraft → Check for Updates…" (`CommandGroup(after: .appInfo)`).
- `SetCraft/Info.plist` bekommt `SUFeedURL`, `SUPublicEDKey`,
  `SUEnableAutomaticChecks`, `SUScheduledCheckInterval=86400`. Beide
  REPLACE_ME-Platzhalter werden vom Release-Skript als harter Fehler
  gemeldet, damit kein Release versehentlich ungültige Sparkle-Werte
  ausliefert.
- `SetCraft/SetCraft.entitlements` zusätzlich `network.client` (Sparkle muss
  HTTPS gegen den Appcast können).
- `scripts/ExportOptions.plist` für `developer-id`-Export mit
  Hardened Runtime.
- `scripts/release.sh` — vollständige Pipeline:
  1. `xcodebuild archive`
  2. `xcodebuild -exportArchive`
  3. ZIP-Upload + `notarytool submit --wait` für die `.app`
  4. `stapler staple` auf die `.app`
  5. DMG via `hdiutil create` (inkl. `/Applications`-Symlink)
  6. `codesign --timestamp` auf das DMG
  7. `notarytool submit --wait` für das DMG
  8. `stapler staple` auf das DMG
  9. Falls Sparkles `generate_appcast` im `$SPARKLE_BIN_DIR` oder
     `$PATH` liegt: signiert die DMGs in `build/release/dist` mit dem
     EdDSA-Privat-Key aus dem Keychain und schreibt `appcast.xml`.
  10. `spctl --assess` als informativer Selbsttest.
  Vorflug-Checks: Developer-ID-Identity im Keychain vorhanden, Notarytool-
  Profil eingerichtet, keine REPLACE_ME-Reste in `Info.plist`.
- `build/release/` in `.gitignore`.
- `docs/DISTRIBUTION.md` — vollständige Einrichtungs- und Release-
  Anleitung: Developer-ID-Zertifikat, Notarytool-Profil
  (`xcrun notarytool store-credentials`), Sparkle-EdDSA-Schlüssel
  (`generate_keys`), Appcast-Hosting, Version-Bump, GPL-Hinweis,
  Troubleshooting.

### Was du vor dem ersten Release tun musst

1. „Developer ID Application"-Zertifikat im Apple-Developer-Account
   erstellen und ins Login-Keychain laden.
2. App-spezifisches Passwort generieren und
   `xcrun notarytool store-credentials AC_SETCRAFT ...` ausführen.
3. `generate_keys` aus dem Sparkle-Bin-Verzeichnis laufen lassen; den
   Public-Key in `SetCraft/Info.plist` als `SUPublicEDKey` eintragen.
   Private-Key bleibt im Keychain.
4. `SUFeedURL` in `SetCraft/Info.plist` auf die echte Appcast-URL setzen.
5. `MARKETING_VERSION` und `CURRENT_PROJECT_VERSION` im Xcode-Projekt
   bumpen.
6. `./scripts/release.sh` ausführen.

### Was bewusst NICHT mit drin ist

- **App-Store-Distribution** — Pfad wäre `app-store-connect`-Method im
  ExportOptionsPlist und ein eigener Skript-Zweig. Solange das Ziel
  „außerhalb des App Stores" ist, würde das nur Komplexität ohne Nutzen
  bringen.
- **CI/CD** (GitHub-Actions-Workflow). Der lokale Pfad reicht
  vorerst; einen CI-Wrapper kann man später um `release.sh` legen.
- **Deployment-Target-Senkung** — bleibt bei macOS 26.5, wie besprochen.

---

## Sitzung 2026-06-02 — Distribution einsatzbereit, Waveform-Prefetch, Dark als Default

Drei voneinander unabhängige Themen, alle gepusht auf `origin/main`.
Build (`xcodebuild ... -destination 'generic/platform=macOS'`) grün.

### Distribution — von „vorbereitet" auf „einsatzbereit"

Was vorher noch zu tun war (siehe Liste oben unter „Was du vor dem ersten
Release tun musst") ist abgehakt:

- **Developer-ID-Application**-Zertifikat im Login-Keychain
  (`Developer ID Application: Beat Buehler (D75S77JA58)`). Apple-Dev-Cert
  läuft daneben auf Team `RXLQ7SLWKT` — wirkt sich nicht auf den Release-
  Build aus, der ist hart auf `D75S77JA58` verdrahtet.
- **Notarytool-Profil** `AC_SETCRAFT` angelegt
  (`xcrun notarytool history --keychain-profile AC_SETCRAFT` antwortet).
- **Sparkle-EdDSA-Schlüsselpaar** erzeugt; Public-Key
  `dSzx1684Glnr7zn9W3Xmbw8W05gdtc0LH6cRFL9JREI=` in `SetCraft/Info.plist` als
  `SUPublicEDKey`, Private bleibt im Login-Keychain.
- `SUFeedURL` zeigt auf `https://synapsetm.github.io/SetCraft/appcast.xml`.
- **Repo auf public** umgestellt (auch nötig wegen GPL-Pflicht), **GitHub
  Pages** auf `main` / `/docs` aktiviert. Verifiziert über `curl` auf
  bestehende Dateien im `docs/`-Ordner.

`scripts/release.sh` wurde **vollautomatisiert** (Commit `4888d78`):

- Neue Pflicht-Preflights: `gh` installiert und eingeloggt, Repo-Zugriff
  möglich, lokale Commits gepusht, kein detached HEAD, Release-Tag nicht
  schon vergeben. `generate_appcast` muss zwingend gefunden werden
  (DerivedData-Fallback im Skript), sonst bricht es ab.
- Schritt 7 (neu): `gh release create v<MARKETING_VERSION>-<BUILD_NUMBER>`
  legt das Release am aktuellen Branch-Tip an und lädt die DMG hoch.
  Idempotenter zweiter Lauf via `gh release upload --clobber`.
- Schritt 8 (neu): `generate_appcast --download-url-prefix=…` zeigt im
  `enclosure`-Tag direkt auf die GitHub-Release-Asset-URL; Ergebnis wird
  nach `docs/appcast.xml` kopiert, committet
  (`release(v…): appcast aktualisieren`) und auf `origin` gepusht. GitHub
  Pages publiziert das Appcast damit ohne weiteren Eingriff.

`docs/DISTRIBUTION.md` und der Pipeline-Kopf in `release.sh` sind auf die
neue Reihenfolge umgeschrieben. Die alte Sektion „Was du vor dem ersten
Release tun musst" oben gilt nur noch als Historie.

Pro Release reicht: `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`
anheben → commit & push → `./scripts/release.sh`.

### Waveform-Prefetch an die Analyze-Trigger gekoppelt (Commit `13e235d`)

Vorher wurde die Waveform nur für den **aktiv geladenen** Player-Track via
`WaveformViewModel.setActiveURL` berechnet. Der Bulk-„Analyze missing"-
Button liess die Waveforms unberührt, und auch Tracks mit vollständigen
Tags hatten beim Klick keinen Cache-Vorlauf.

- `SetCraftApp.init()` erzeugt jetzt **einen** `WaveformCache` und reicht
  ihn an `WaveformViewModel(cache:)` UND
  `LibraryViewModel(... waveformCache:)`. Memory-Cache wird geteilt,
  DB-Cache war es eh.
- `LibraryViewModel.prefetchWaveform(_:)` (privat) startet pro URL einen
  Detached-Task auf `cache.waveform(for:)`, serialisiert über
  `waveformPrefetchInflight: Set<URL>`, Ergebnis landet still im Cache.
- `analyzeIfNeeded(_:)` ruft den Prefetch jetzt **unconditional** vor dem
  nil-Guard für BPM/Key.
- `analyzeAllMissing()` läuft jetzt über **alle** Tracks (statt nur über
  die mit fehlenden Tags); die teure aubio/KeyFinder-Pipeline läuft
  weiterhin nur dort, wo der nil-Guard in `analyzeIfNeeded` greift.

Effekt: ein Klick auf „Analyze missing" wärmt zusätzlich den
Waveform-Cache für die ganze Library vor; spätere Track-Loads bekommen
die Welle aus dem DB-Hit.

### Dark Mode als Default (Commit `9116280`)

`AppearancePreference.dark` ist neuer Initial-Wert an beiden Stellen:
dem `@AppStorage("appearance")`-Default und dem `init()`-Fallback, der
`NSApp.appearance` **vor** dem ersten Window setzt (sonst blitzt das
System-Schema kurz auf). Bestehende Installationen mit vorhandenem
`UserDefaults`-Key behalten ihre Wahl — der Default greift nur, wenn der
Key noch nicht existiert.

### Repo-Sichtbarkeit

`synapsetm/SetCraft` ist jetzt **public** (Voraussetzung für GitHub Pages
und ohnehin nötig wegen aubio/libKeyFinder = GPL).

---

## Sitzung 2026-06-02 (Abend) — Player-UX, Lizenz-About und Brand-Rename auf SetCraft

Drei zusammenhängende Themen in einer Sitzung. Build und Release am Ende grün.

### Player-UX (Commit `f261679`)

- **Autoplay beim Laden** — `PlayerViewModel.load(url:)` ruft direkt
  `player.play()`. Wirkt aus Library-Klick, Drag & Drop und Datei-Picker.
- **Mausrad-/Trackpad-Scrubbing über der Waveform** — `WaveformView`
  hat ein NSViewRepresentable-Overlay (`ScrollWheelCatcher`), das in
  `hitTest` nur Scroll-Events abfängt und Klicks an SwiftUI durchreicht.
  `ContentView` rechnet das Delta in einen relativen Seek um (0,5 ×
  Tracklänge pro voller Waveform-Breite).
- **Re-Analyze als Library-Befehl** — `LibraryViewModel.reanalyze(_:)`
  umgeht den `needsBPM || needsKey`-Guard und erzwingt eine frische
  BPM/Key-Analyse. Toolbar-Knopf neben „Analyze" plus Kontextmenü-
  Eintrag (Mehrfach-Selektion möglich).
- **Manuelle BPM-Skalierung im Kontextmenü** — `×2`, `÷2`, `×1.5`,
  `÷1.5` (Triolen-Fix). `LibraryViewModel.scaleBPM(_:factor:)`
  multipliziert, rundet auf eine Nachkommastelle, schedulet `save`.
- **Triolen-bewusste Oktavkorrektur in `BPMRangePreset.corrected()`** —
  prüft jetzt die Faktoren `½, ⅔, 1, 1½, 2` und nimmt den Kandidaten,
  der dem Bereichs-Mittelpunkt am nächsten liegt. Behebt die typische
  aubio-Fehldetektion 146 → 97,7 (≈ ⅔). Originalwert hat Vorrang, wenn
  er im Bereich liegt — keine Fehlkorrekturen für echte 95-BPM-Tracks.
- **Neuer Psy-Trance-Preset** (135–165) im BPM-Menü.
- **Combined Time Row** — `MM:SS / -MM:SS` (gespielt / verbleibend)
  links, Gesamtdauer rechts.

### App-Politur und Lizenzhinweise (Commit `784e374`)

- **Tab-Bar entfernt** — `NSWindow.allowsAutomaticWindowTabbing = false`
  in `AppDelegate.applicationWillFinishLaunching` lässt den View-Menü-
  Eintrag „Show Tab Bar" verschwinden.
- **About-Panel mit voller Lizenzauflistung** — eigener
  `CommandGroup(replacing: .appInfo)` mit `orderFrontStandardAboutPanel`
  und attributed-string-Credits für aubio (GPLv3), libKeyFinder (GPLv3),
  FFTW (GPLv2+), TagLib (LGPLv2.1/MPL), utfcpp (Boost SL 1.0), Sparkle
  (MIT) und GRDB.swift (MIT). Verweis aufs öffentliche Repo deckt
  GPL §6 (Source-Bereitstellung) ab.
- **`NSHumanReadableCopyright`** in `Info.plist` für den About-Header.

### Erstes Release Setify v1.0-1 (Commit `8a60601`)

`scripts/release.sh` mit `DEVELOPER_DIR=/Applications/Xcode.app/...`
und `SPARKLE_BIN_DIR=...` einmal durchgelaufen — beide Notarisierungen
(`.app` und `.dmg`) `Accepted`, `spctl --assess` grün, DMG als Asset
am Tag `v1.0-1` hochgeladen, Appcast nach `docs/appcast.xml` gepusht.

### Brand-Rename Setify → SetCraft (Commits `aca2dad`..`c72c048`)

Trademark-Recherche: Setify vs. Spotify ist ein echtes Konflikt-Risiko
(„-ify"-Suffix im Audio-Bereich, bekannte Marke). Geprüfte
Alternativen: SetPrep (existierende Beta-DJ-App, direkt belegt),
Crately (CrateDigger als 1:1-Konkurrent), Mixory (Möbel-Brand andere
Klasse, akzeptabel), **SetCraft** (frei, `.ch`/`.app`/`.dev` alle frei,
kein DJ-Konflikt). Umbenennung in sieben dedizierten Commits:

1. Bundle-ID `ch.beat.buehler.Setify` → `ch.buehler.beat.SetCraft`,
   In-Code-Strings, About-Button-Label, Credits-Header.
2. Swift-Modul `SetifyCore` → `SetCraftCore` (612 Datei-Renames per
   `git mv`, 22 Import-Sites per `sed`, `pbxproj`-XCLocalSwiftPackage-
   Reference nachgezogen).
3. ObjC-Bridges `SetifyAnalyzerBridge`/`SetifyTagBridge` →
   `SetCraftAnalyzerBridge`/`SetCraftTagBridge`, Umbrella-Header
   `SetCraftCoreObjC.h` mit angepassten `#import`-Pfaden.
4. Projektdateien: `Setify.xcodeproj` → `SetCraft.xcodeproj`,
   `Setify/` → `SetCraft/`, `SetifyApp.swift` → `SetCraftApp.swift`,
   Entitlements. pbxproj-`TARGET_NAME` & `PRODUCT_NAME` mitgezogen.
5. `scripts/release.sh` Konstanten (PROJECT/SCHEME/APP_NAME/BUNDLE_ID/
   REPO_SLUG/NOTARY_PROFILE), GitHub-Release-Titel und Doku
   (README/STATUS/SPEC/CLAUDE/DISTRIBUTION/mockup) wholesale auf
   SetCraft umgestellt.
6. GitHub-Repo `synapsetm/Setify` → `synapsetm/SetCraft` via
   `gh repo rename`. GitHub legt automatisch Redirects an — alte
   URLs bleiben funktionsfähig. Lokales Remote per
   `git remote set-url`, `SUFeedURL` in `Info.plist` auf neuen
   Pages-Pfad.
7. **SetCraft v1.0-1 freigegeben** — altes Setify-v1.0-1-Release
   gelöscht (0 Downloads, am gleichen Tag publiziert), neues
   notarisiertes DMG als `SetCraft-1.0-1.dmg` unter
   `https://github.com/synapsetm/SetCraft/releases/tag/v1.0-1`,
   Appcast zeigt jetzt auf die SetCraft-URLs.

### Filesystem nachgezogen

- Repo-Wurzel von `/Users/beatbuehler/Entwicklung/Setify` auf
  `/Users/beatbuehler/Entwicklung/SetCraft` umbenannt.
- Alte `DerivedData/Setify-…` (1,2 GB) und der erste
  `DerivedData/SetCraft-dmyxsmblyhmotcehxtywilcxcktk` (Build vom
  alten Pfad) entfernt; aktive DerivedData ist jetzt
  `SetCraft-fehyclbsmkhnjydjnovlebenftxn`.

### Was noch ansteht (manuelle Aktionen)

- **Notarytool-Profil umbenennen** — `xcrun notarytool store-credentials
  AC_SETCRAFT --apple-id … --team-id D75S77JA58` ausführen (App-
  spezifisches Passwort interaktiv). Anschließend `AC_SETIFY` in
  Keychain Access löschen. Release-Skript hat `AC_SETCRAFT` als
  Default; `AC_SETIFY` läuft als Fallback weiter.
- **Domain-Reservierungen** — `setcraft.ch`/`setcraft.app`/`setcraft.dev`
  alle frei (Stand 2026-06-02). Wenn Marketing-Site geplant, jetzt
  schnappen.
- **Trademark-Check Klasse 9** — bei EUIPO eSearch plus und Swissreg
  vor erster ernsthafter Außenkommunikation manuell prüfen.
