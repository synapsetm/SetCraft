# STATUS — SetCraft

Ergebnis-fokussierter Projektstand. Begleitend zu `CLAUDE.md` (Leitplanken)
und `SPEC.md` (Spezifikation und Phasenplan). Die frühere sitzungsweise
Chronologie ist bewusst entfernt — hier steht nur, was aktuell gilt.

Letzte Aktualisierung: 2026-09-12.

---

## Aktueller Stand

- **Phasen 0–5a komplett**, **Phase 5b (iOS-Target) voll umgesetzt**.
- **Mac-Release:** v1.2-14 (Build 14), notarisiert, Sparkle-Auto-Update live.
  Bringt Löschen aus der Library, die DJ-Mix-Erkennung, die mitwachsende
  Waveform und die Scope-/Beenden-Korrekturen (s. u.).
  v1.0-11 hatte einen Kaltstart-Bug (Öffnen aus dem Finder erzeugte kein
  Fenster, s. u.) und sollte übersprungen werden.
- **iOS-Release:** 1.2 (Build 14) auf TestFlight. `exportArchive` scheitert
  weiterhin am Cloud-Signing (s. u.), der Upload lief deshalb wie gehabt
  manuell über den Xcode Organizer.
- **Tests:** `swift test` im `SetCraftCore`-Paket grün — 91 Tests
  (BPM/Key/Rating/Waveform/Waveform-Streaming/Ordner-Scan/Security-Scope/
  Mix-Heuristik).
- **Build (Mac):** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodebuild -project SetCraft.xcodeproj -scheme SetCraft -destination
  'platform=macOS' build` — sauber.
- **Build (iOS):** Scheme „SetCraft iOS", Simulator-Destination.
- **Repo:** https://github.com/synapsetm/SetCraft (public, GPL-Pflicht).

Code-Organisation: **Weg B** — lokales Swift Package `SetCraftCore` mit der
gesamten plattformfreien Logik; beide App-Targets (macOS, iOS) konsumieren es.
C/C++-Libs (aubio, libKeyFinder, TagLib) liegen als vorgebaute
`.xcframework`s in `SetCraftCore/Vendor/`, gekapselt hinter ObjC++-Bridges.

---

## Was die Apps können

### Bibliothek (beide Plattformen)
- Mehrere persistente Quellen über Security-Scoped Bookmarks; letzte aktive
  Quelle wird beim Start wiederhergestellt. iOS zieht Quellen (inkl. NAS/SMB)
  über die Files-App / FileProvider.
- SQLite-Cache (GRDB) für Track-Metadaten und Waveforms. **Datei = Quelle der
  Wahrheit**, Cache invalidiert via `mtime`. Kalter Scan rechnet im
  Hintergrund, warmer Scan kommt aus dem Cache.
- Spalten: Titel, Artist, BPM, Key, Rating, Genre, Album, Label, Year, Type,
  Bitrate, Size, Filename, Modified, Plays. Mac inline-editierbar
  (Text + BPM + Sterne); iOS über Edit-Sheet. Sortierbar; Sortier-Reihenfolge
  wird bei Tag-Edits eingefroren (Eintrag springt nicht), `applySortOrder()`
  läuft nur bei Scan-Ende, Header-Klick und Refresh.
- Auto-Analyse (BPM + Key) beim Track-Load plus Batch „Fehlende analysieren";
  Re-Analyze erzwingt Neuberechnung. Ergebnisse fließen sofort in Datei-Tags —
  auch dann, wenn die Quelle inzwischen gewechselt wurde (Zuordnung über die
  URL, nicht über die pro Scan neu vergebene `Track.id`).
- **DJ-Mix-Erkennung:** Dateien ab 20 Minuten (`Track.isLikelyDJMix`, allein
  aus der Dauer) nimmt der automatische Pfad von BPM/Key-Analyse **und**
  Waveform-Prefetch aus — über einen ganzen Mix sind beide Werte wenig wert,
  kosten aber Minuten und viel Speicher. Ausdrückliches Re-Analyze fragt nach.
- **Löschen** (macOS-Kontextmenü, iOS-Swipe): in den Papierkorb, nach
  Rückfrage. Wo es keinen Papierkorb gibt (SMB/NAS), kommt eine zweite,
  ausdrückliche Rückfrage fürs endgültige Löschen.
- Play-Count (app-lokal, nicht in Datei-Tags) mit Reset pro Ordner.
- Quellen sind entweder **Ordner** (flacher Scan — nur der Ordner selbst,
  Unterverzeichnisse kommen bei Bedarf als eigene Quelle dazu) oder
  **einzelne Dateien** (`SourceKind`).
  Einzeldatei-Quellen entstehen auf dem Mac, wenn ein Track von
  aussen geöffnet wird (Standard-Player, „Öffnen mit", Drag & Drop) und noch
  keine Quelle ihn abdeckt: aufgenommen wird nur dieser Track, ohne Rückfrage.
  Möglich, weil sich auf eine von aussen gereichte Datei ein Security-Scoped
  Bookmark erzeugen lässt — auf ihr *Verzeichnis* dagegen nicht, das bräuchte
  eine explizite Freigabe per Picker.

### Player
- macOS: fixe Waveform, beweglicher Playhead; iOS: Center-Playhead, Waveform
  scrollt darunter (CDJ-Stil), horizontal + vertikal (Landscape).
- RGB-Waveform: vDSP-FFT, drei Bänder (Bass < 200 Hz / Mitten / Höhen > 2 kHz),
  additiv, `pow(0.4)`-Gamma. SwiftUI-Canvas auf beiden Plattformen.
- Die Welle entsteht **blockweise mit dem Decoder** und wächst von links nach
  rechts, statt erst am Ende zu erscheinen (`PCMLoader.stream`,
  `WaveformCache.stream(for:)`). Nichts von der Datei liegt dabei am Stück im
  Speicher — ein zweistündiger Mix kostete vorher ~1,3 GB.
- Tempo-Chip mit Master-BPM-Logik (±8 %), Key-Chip read-only mit
  Camelot-Farben. Key-Lock ist immer an (`AVAudioUnitTimePitch` entkoppelt
  Rate/Pitch); Master-Key = Modus A (exakter Shift, bei Dur/Moll-Mismatch
  unangetastet).
- Autoplay beim Laden, Prev/Next (Pfeiltasten, folgen der Sortierung),
  Waveform-Scrub, Sterne-Rating, Album-Cover.
- iOS: Lock-Screen / Control-Center / AirPods über `MPRemoteCommandCenter` +
  `MPNowPlayingInfoCenter`; `AVAudioSession`-Interruption + Route-Change;
  Background-Audio; Player-Swipe für Track-Wechsel.

### Distribution
- macOS: `scripts/release.sh` — Build → Notarize → DMG → GitHub-Release →
  Sparkle-Appcast (`docs/appcast.xml`, GitHub Pages) in einem Lauf.
- iOS: `scripts/release-ios.sh` → TestFlight (ASC API Key).
- About-Panel mit vollständigen Lizenz-Credits (GPL §6).
- Lokalisiert (EN + DE, Auto-Switch). Dark Mode als Default.

---

## Wichtige gelöste Probleme (Ergebnis-Referenz)

- **NAS/SMB-Tag-Writes:** `.itemReplacementDirectory` + `replaceItemAt`
  scheitern auf SMB (setattrlist/xattr → ENOTSUP/EPERM, Sandbox-Scope). Fix in
  `TagLibTrackStore.save`: Sibling-Temp im selben Verzeichnis, `replaceItemAt`
  als erster Versuch, Fallback auf Rename-über-Backup mit Wiederherstellung.
  `StoreError.fileSystem` trägt `stage` + NSError-Domain/Code.
- **Security-Scope beim Quellenwechsel:** `selectFolder` schloss den Scope der
  alten Quelle sofort, während Analysen und Tag-Writes noch liefen. Der
  Schreibvorgang verlor mitten in der Operation den Zugriff — `copyItem` ging
  noch durch, der Rename scheiterte Millisekunden später mit `EPERM`.
  `SecurityScope`/`SecurityScopeRegistry` (Core) zählen die Nutzer mit:
  abgemeldet wird sofort, geschlossen erst, wenn das letzte Token zurück ist.
  `token(for:)` findet auch einen bereits abgemeldeten, noch offenen Scope.
- **`Track.id` ist die Identität des Scans, nicht der Datei.** `Track.init`
  vergibt eine frische UUID, kein Aufrufer übergibt je eine — jedes
  Neuaufbauen der Liste (Ordnerwechsel, Refresh, Import, Löschen) vergibt neue
  IDs. Wer eine laufende Operation über die ID zuordnet, verliert sie: die
  fertige Analyse fand ihre Zeile nicht mehr und wurde samt Tag-Write
  verworfen. Zuordnung deshalb über die **URL**; existiert die Zeile nicht
  mehr, schreibt `persistOrphanedAnalysis` das Ergebnis trotzdem (Basis frisch
  aus dem Repository, damit zwischenzeitliche Tag-Edits erhalten bleiben).
- **`AVAudioFile.read(into:)` wirft am Dateiende**, statt 0 Frames zu liefern
  (`nilError` aus dem ExtAudioFile-Pfad). Das wurde als Decoder-Fehler
  gewertet, worauf der AVAssetReader-Fallback die bereits vollständig gelesene
  Datei ein zweites Mal dekodierte — jede Analyse und jede Waveform lief
  doppelt. Ein Wurf nach bereits gelieferten Frames gilt jetzt als Dateiende
  (`PCMLoader.streamViaAVAudioFile`).
- **Beenden-Dialog-Schleife:** `applicationShouldTerminateAfterLastWindowClosed`
  wird von AppKit bei **jedem** schliessenden Fenster geprüft — auch beim
  eigenen modalen Dialog. War das Hauptfenster schon zu, löste das Schliessen
  des Dialogs den nächsten Beenden-Versuch aus: „Abbrechen" führte in eine
  Endlosschleife ohne Weg zurück in die App. `isHandlingTerminationPrompt`
  unterbricht das, gelöst wird die Sperre beim `didBecomeMainNotification`
  des wiederhergestellten Fensters.
- **Playhead-Sync (Mac):** korrekt über `playerNode.outputPresentationLatency`
  (nicht outputNode-only), Waveform-Progress auf Wave-Zeitachse statt
  `player.duration`, Spalten-Aggregation per Float-Division. Ergebnis:
  konstanter ~30-ms-Offset, kein wachsender Drift.
- **MP3-Decode-Fallback:** `AVAudioFile` wirft bei manchen MP3-Headern
  `_GenericObjCError 0` → `AVAssetReader`-Fallback (CoreMedia-Decoder,
  native Sample-Rate, kein Resampling).
- **Aktiver Track:** Schreibvorgänge auf die im Player offene Datei werden mit
  `StoreError.fileInUse` abgelehnt, in `pendingSaves` geparkt und beim
  Track-Wechsel nachgeholt (Mac + iOS). iOS flusht zusätzlich bei
  `scenePhase == .background`.
- **Sparkle-Sandbox:** XPC-Services über `SUEnableInstallerLauncherService` +
  `SUEnableDownloaderService` in Info.plist und
  `temporary-exception.mach-lookup.global-name` (`<bundle-id>-spks`/`-spki`)
  in den Entitlements. Kein Bundling der XPCs, kein `--deep`-Resign.
- **Seek-Bug:** `scheduleSegment`-Completion feuert auch bei abgebrochenem
  Segment → `scheduleGeneration`-Zähler ignoriert überholte Callbacks.
- **Ein-Fenster-Verhalten (Mac):** Datei-Open-Events laufen über
  `AppDelegate.application(_:open:)` (nicht `.onOpenURL`), die Scene ist ein
  `Window` statt einer `WindowGroup` — letztere öffnet pro gereichter Datei ein
  zusätzliches Fenster. URLs vor dem Scene-Start werden gepuffert.
  Fenster schliessen beendet die App
  (`applicationShouldTerminateAfterLastWindowClosed`); wird der Speichern-
  Dialog abgebrochen, holt ein Reopen-Ereignis das Fenster zurück
  (`makeKeyAndOrderFront` auf dem geschlossenen NSWindow liefert nur eine
  leere Hülle).
  **Sackgasse (in v1.0-11 ausgeliefert, in Build 12 behoben):**
  `.handlesExternalEvents(matching: [])` auf einer `WindowGroup` unterdrückt
  das Zusatzfenster zwar, lässt aber einen Kaltstart *mit* Datei ganz ohne
  Fenster enden — Prozess und Menüleiste da, sonst nichts.
- **Appearance (Mac):** `NSApplication.shared.appearance` ist einzige
  Wahrheitsquelle (nicht `.preferredColorScheme`), auf jedem Window gesetzt.
- **BPM-Oktav-/Triolen-Korrektur:** `BPMRangePreset.corrected()` prüft
  Faktoren ½, ⅔, 1, 1½, 2 und nimmt den bereichsnächsten Kandidaten;
  Originalwert hat Vorrang, wenn im Bereich. Presets: Universal / DnB /
  Psy-Trance / House / HipHop / Disco.

---

## Referenz-/Build-Stolpersteine

- `xcode-select` zeigt auf CommandLineTools → jeder `xcodebuild`/`xcrun`-Aufruf
  braucht `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Sparkle-CLI (`generate_keys`, `generate_appcast`) liegt in DerivedData; für
  `release.sh` ggf. `SPARKLE_BIN_DIR` explizit setzen.
- Nach jedem Build/Release-Lauf registriert LaunchServices die Kopien aus
  `build/release/` und DerivedData unter derselben Bundle-ID — ein Doppelklick
  im Finder kann dann eine Artefakt-Kopie statt `/Applications/SetCraft.app`
  starten. Prüfen mit `lsregister -dump | grep SetCraft.app`, aufräumen mit
  `lsregister -u <pfad>` und `lsregister -f -R /Applications/SetCraft.app`.
  Welche Version wirklich läuft: About-Panel bzw.
  `ps -p $(pgrep -x SetCraft) -o comm=`.
- iOS-TestFlight: `exportArchive` bricht am Cloud-Signing-Stolperstein ab
  („No signing certificate iOS Distribution found") — Workaround: Upload
  manuell über Xcode Organizer. Verhält sich nicht reproduzierbar.
- Rating-Kommentar-Token-Format: `★★★★☆ | <rest>` (menschenlesbar in Serato +
  Rekordbox), Round-Trip in `RatingPrefix.parse/format`.
- WAV ist als Tag-Ziel schwach → UI-Warnung im Edit-Sheet, Write läuft durch.
- Rekordbox lädt geänderte Tags nicht automatisch neu („reload tags" nötig).
- Vendor-Versionen: TagLib 2.3.1 (utfcpp 4.1.1), libKeyFinder 2.2.8 + fftw
  3.3.11, aubio 0.4.9 (letztes Release seit 2019 — kein Upgrade-Pfad).
  Gepinnt jeweils oben in `Vendor/*/build-*.sh`.
- Vendor-Binärgrößen: TagLib 16 MB, KeyFinder 8 MB, aubio 5 MB.
- Bundle-IDs: Mac `ch.buehler.beat.SetCraft`, iOS `ch.buehler.beat.SetCraft.iOS`.
  Sparkle-EdDSA-Public-Key + `SUFeedURL` in `SetCraft/Info.plist`.
- Notarytool-Keychain-Profil: `AC_SETCRAFT` (Team `D75S77JA58`,
  Developer ID Application: Beat Buehler).
- iOS: iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), iPad-Ziel verworfen.

---

## Offene Punkte

- **iCloud-Sync der Library** zwischen Mac und iPhone (App Group + CloudKit).
- **Cloud-Signing für iOS-TestFlight** reproduzierbar machen (API-Key-Rolle
  hochstufen oder manuelles Distribution-Cert + manual signing).
- **WAV-Tagging** tiefer lösen (aktuell nur UI-Warnung).
- **Crates / Playlists / Suche / History** (SQLite-Basis steht).
- **Metal-Renderer** für die Waveform (Canvas reicht aktuell).
- **Live-Activities** (iOS) für die Wiedergabe.
- **Multi-Source-Aggregation** („Alle Tracks" über mehrere Ordner).
- **Phase 5c / SFBAudioEngine** (Ogg Vorbis, schnelleres FLAC) — erst bei Bedarf.
- **Waveform-Prefetch-Throttling** bei sehr großen Libraries (TaskGroup-Limit).
