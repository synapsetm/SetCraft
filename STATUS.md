# STATUS — SetCraft

Ergebnis-fokussierter Projektstand. Begleitend zu `CLAUDE.md` (Leitplanken)
und `SPEC.md` (Spezifikation und Phasenplan). Die frühere sitzungsweise
Chronologie ist bewusst entfernt — hier steht nur, was aktuell gilt.

Letzte Aktualisierung: 2026-08-13.

---

## Aktueller Stand

- **Phasen 0–5a komplett**, **Phase 5b (iOS-Target) voll umgesetzt**.
- **Mac-Release:** v1.0-11 (Build 11), notarisiert, Sparkle-Auto-Update live.
  **Achtung:** v1.0-11 hat einen Kaltstart-Bug (Öffnen aus dem Finder erzeugt
  kein Fenster, s. u.); der Fix liegt unveröffentlicht im `main` und gehört
  als Build 12 nachgeschoben.
- **iOS-Release:** Build 12 auf TestFlight.
- **Tests:** `swift test` im `SetCraftCore`-Paket grün (BPM/Key/Rating/Waveform).
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
  Re-Analyze erzwingt Neuberechnung. Ergebnisse fließen sofort in Datei-Tags.
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
- iOS-TestFlight: `exportArchive` bricht am Cloud-Signing-Stolperstein ab
  („No signing certificate iOS Distribution found") — Workaround: Upload
  manuell über Xcode Organizer. Verhält sich nicht reproduzierbar.
- Rating-Kommentar-Token-Format: `★★★★☆ | <rest>` (menschenlesbar in Serato +
  Rekordbox), Round-Trip in `RatingPrefix.parse/format`.
- WAV ist als Tag-Ziel schwach → UI-Warnung im Edit-Sheet, Write läuft durch.
- Rekordbox lädt geänderte Tags nicht automatisch neu („reload tags" nötig).
- Vendor-Binärgrößen: TagLib 13 MB, KeyFinder 8 MB, aubio 5 MB.
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
