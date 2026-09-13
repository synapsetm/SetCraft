# STATUS — SetCraft

Ergebnis-fokussierter Projektstand. Begleitend zu `CLAUDE.md` (Leitplanken)
und `SPEC.md` (Spezifikation und Phasenplan). Die frühere sitzungsweise
Chronologie ist bewusst entfernt — hier steht nur, was aktuell gilt.

Letzte Aktualisierung: 2026-09-13.

---

## Aktueller Stand

- **Phasen 0–5a komplett**, **Phase 5b (iOS-Target) voll umgesetzt**.
- **Mac-Release:** v1.3-15 (Build 15), notarisiert, Sparkle-Auto-Update live.
  Bringt die Tag-Ergänzung aus Dateinamen (vier Stufen, Review-Sheet,
  Discogs-Abgleich) auf beiden Plattformen.
  Bringt Löschen aus der Library, die DJ-Mix-Erkennung, die mitwachsende
  Waveform und die Scope-/Beenden-Korrekturen (s. u.).
  v1.0-11 hatte einen Kaltstart-Bug (Öffnen aus dem Finder erzeugte kein
  Fenster, s. u.) und sollte übersprungen werden.
- **iOS-Release:** 1.3 (Build 15) auf TestFlight. `exportArchive` scheitert
  weiterhin am Cloud-Signing (s. u.), der Upload lief deshalb wie gehabt
  manuell über den Xcode Organizer.
- **Tests:** `swift test` im `SetCraftCore`-Paket grün — 222 Tests
  (BPM/Key/Rating/Waveform/Waveform-Streaming/Ordner-Scan/Security-Scope/
  Mix-Heuristik/Dateinamen-Parser/Ordner-Schema/Zwillings-Abgleich/
  Vorschlagskette/Discogs).
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

### Tag-Ergänzung aus Dateinamen (beide Plattformen)
Für Tracks ohne saubere Artist/Title-Tags. Vier Stufen, jede darf die vorige
überstimmen, die Confidence wandert mit (`SetCraftCore/Metadata/`):

1. **`FilenameParser`** — zerlegt „Artist - Title (Mix)", räumt Rip-Reste
   (Seiten-URLs, `[320kbps]`, `(WEB)`, Scene-Kürzel als drittes Feld),
   Tracknummern, Vinyl-Positionen und Label-Katalognummern weg. Enthält der
   Name kein Leerzeichen, sind Underscores die Wortgrenze — das passiert ganz
   zu Beginn, sonst überlebt `_` mitten im Titel. Mix-Version und `feat.`
   bleiben **im Titel** (Serato/Rekordbox zeigen nur den Titel), werden aber
   separat ausgewiesen. Eine nackte Mix-Bezeichnung wird eingeklammert
   („Higher Dimension Original MIx" → „… (Original Mix)") und Abkürzungen
   werden ausgeschrieben („rmx" → „Remix"); mehrdeutige Wörter wie „Dub"
   lösen das nicht aus.
2. **`PatternLearner`** — lernt das Namensschema eines Ordners aus den
   Dateien, die **schon** Tags haben, und richtet die untagged Geschwister
   danach aus. Damit ist „Title - Artist" auflösbar, was aus einem Dateinamen
   allein nicht geht. Minimum: drei Belege, 75 % Zustimmung.
   Der **Ordnername ist bewusst keine Quelle** — er trägt zu oft
   Download-Datum oder Sampler-Titel, und das landete dann in Album und Jahr
   jeder Datei darin.
3. **`DuplicateMatcher`** — getaggter Zwilling in der Bibliothek, gefunden
   über Dauer (±2 s) plus Dateigrösse bzw. Namensähnlichkeit. Verlässlichste
   Offline-Quelle, weil die Tags vom Nutzer selbst kuratiert sind. Gesucht
   wird über die **ganze** Bibliothek (`DatabaseService.taggedTracks()`), nicht
   nur in der offenen Quelle — der wichtigste Fall ist ja gerade die rohe
   Kopie im Download-Ordner und die saubere im Album-Ordner. Verglichen wird
   der **geparste** Name (Artist und Titel getrennt, ohne Mix-Klammer), nicht
   der rohe Dateiname — sonst scheitert der Abgleich an Scene- und
   Seiten-Kürzeln, sobald die Dateigrössen nicht exakt übereinstimmen. Deshalb
   überstimmt **Discogs einen Zwilling nicht**: dessen Wert bleibt stehen, der
   Katalogwert wird Alternative, und die Uneinigkeit kostet 0.1 Confidence.
4. **`DiscogsResolver`** — Gegenprüfung gegen api.discogs.com. Policy
   `off` / `whenUncertain` (Default) / `always`; „unsicher" heisst unklare
   Reihenfolge, schwacher Trenner, fehlendes Kernfeld oder ein angefordertes
   Feld, das offline leer bleibt.

Gefüllt werden Artist, Titel, Album, Label, Jahr — Album/Label/Jahr können
dabei nur vom Zwilling oder aus Discogs kommen. **Genre bewusst nicht** —
Discogs-Styles würden eine kuratierte Spalte überschreiben. BPM/Key kommen
weiter aus der Audio-Analyse.

**Mehrere Interpreten** (`ArtistNames`): geschrieben wird **ein** `TPE1`-Frame
mit `, ` als Trenner — so liefert es Beatport, und Serato wie Rekordbox zeigen
den String ohnehin unverändert. Normalisiert wird nur, wo die Struktur
*bekannt* ist: aus Discogs' Artist-Liste (Aufzählungs-Verbinder `&`/`and` →
`, `, Beziehungs-Verbinder wie `feat.`/`vs.` bleiben wortwörtlich) oder aus
einer Zerlegung anhand bekannter Namen. Ein roher Dateiname wird nie
angefasst — „Above & Beyond" ist **ein** Interpret, und das ist aus dem String
allein nicht zu erkennen.

Der harte Fall: Download-Seiten ersetzen jedes Sonderzeichen durch einen
Underscore, aus „Luca Antolini, Andrea Montorsi" wird
`Luca_Antolini_Andrea_Montorsi` — die Grenze ist weg. Wiederhergestellt wird
sie mit Wissen von aussen, zuerst aus der **eigenen Bibliothek**: stehen beide
Namen dort schon in anderen Dateien, ist die Zerlegung eindeutig (wortweises
DP, lückenlose Abdeckung, wenigste Teile gewinnen). Ist nur **einer** der
beiden bekannt — der Normalfall in einer frisch gescannten Bibliothek —, gilt
der Rest als zweiter Interpret; dann aber nur bei genau zwei Teilen, die beide
mindestens zwei Wörter haben. Ist der ganze String selbst ein bekannter Name,
wird nie zerlegt — „Paul van Dyk" bleibt ganz, auch wenn „Paul" bekannt ist.
Kennt **niemand** die Grenze (auch der Katalog nicht), bleibt der String wie er
ist; bei gerader Wortzahl ab vier steht die Mitte-Vermutung aber als
*Alternative* im Menü — ein Klick statt Abtippen, und falsch liegen kann sie
nicht, weil sie nie von selbst in ein Tag wandert.

Beide Stufen hängen an der Bibliothek. Ist sie leer — weil die sauber
getaggten Ordner nie als Quelle gescannt wurden —, können sie prinzipiell
nichts finden. Die Fusszeile des Sheets zeigt deshalb nach jedem Lauf, worauf es sich stützt:
„Bibliothek: n getaggte Tracks · m Interpreten", bei 0 orange hervorgehoben.

**Wer gewinnt bei Widerspruch?** Der **hergeleitete Wert**, nicht der Katalog:
der Dateiname beschreibt die Datei, die vorliegt, der Katalog einen Eintrag,
der eine andere Fassung sein kann. Drei Ausnahmen, alle mit Belegen aus echten
Läufen (`MetadataResolver.catalogWinsContradiction`):

1. **Schreibweise** — die Werte sind fast gleich (≥ 0.6 Ähnlichkeit). Dann hat
   der Katalog das Zeichen, das die Download-Seite verschluckt hat: „IK N" → „Ikøn".
2. **Ergänzung** — unser Titel trägt keine Mix-Bezeichnung, der Katalog schon.
3. **Vertauschte Seiten** — der Katalog kennt unsere beiden Werte über Kreuz.
   Genau die Frage „Artist - Title oder Title - Artist?" kann ein Dateiname
   nicht beantworten, ein Katalog schon.

Tragen **beide** eine Mix-Bezeichnung und sind die verschieden, gewinnt immer
unsere — das ist der Bootleg-Fall. Ein Zwilling aus der Bibliothek wird
ohnehin nie überstimmt.

**Confidence** (0…1, Skala dokumentiert an `SuggestionConfidence`): Dateiname
0.55, mit geklärter Reihenfolge 0.75, Ordner-Schema 0.60–0.90, Zwilling
0.70–0.95, Handeingabe 1.00. Beim Katalog werden drei Lagen unterschieden —
**Bestätigung** (0.75–0.97), **Lücke gefüllt** (0.55–0.90) und **Widerspruch**
(Deckel 0.82, minus 0.12 × Confidence der überstimmten Stufe, minus 0.05 bei
mehreren gleich guten Treffern). Ein Widerspruch erreicht damit nie „hoch" und
wird nie vorausgewählt: die Punktzahl eines Treffers sagt, wie gut er zur
*Anfrage* passt, nicht ob er recht hat — bei einem Bootleg kennt Discogs den
Remix nicht und trifft trotzdem hervorragend auf das Original.

**Geschrieben wird nie automatisch.** Ein Review-Sheet (macOS) bzw.
-Screen (iOS) zeigt pro Feld Ist-Wert, Vorschlag, Quelle und Verlässlichkeit;
vorausgewählt ist nur, was fehlt und als sicher gilt. **Keine Stufe hat immer
recht** — bei einem Bootleg kennt Discogs den Remix nicht und „korrigiert" den
richtigen Dateinamen-Titel kaputt. Verdrängte Werte bleiben deshalb als
Alternativen am Feld hängen (Menü in der Zeile), und jeder Wert ist direkt
editierbar; eine Handeingabe gilt als eigene Quelle mit voller Confidence. Das Übernehmen läuft
durch `applyMetadata` und damit den bestehenden Save-Pfad (Scope-Token,
Serialisierung, Active-Track-Guard).

**Discogs-Eigenheiten, die die Architektur bestimmen:**
- Die Suche arbeitet auf **Release**-Ebene und liefert Artist/Titel nur
  zusammengeklebt („The Persuader - Stockholm"). Die Tracklist gibt es erst
  über `GET /releases/{id}` → **zwei Requests pro Track**. Deshalb werden die
  Suchtreffer erst ohne weiteren Request vorsortiert und nur die besten
  aufgelöst.
- Rate-Limit: 60/min mit Token, 25/min ohne (Token optional, nur für Cover
  nötig). `DiscogsClient` hält ein gleitendes Minutenfenster mit Marge ein,
  liest `X-Discogs-Ratelimit-Remaining` und folgt `Retry-After` bei 429.
  Der **User-Agent ist Pflicht** — generische Werte drosselt Discogs härter,
  ohne es in den Headern zu zeigen.
- Antworten landen roh im SQLite-Cache (Migration `v6`, 30 Tage), damit ein
  zweiter Lauf über denselben Ordner kein Budget kostet.
- Gesucht wird über `track=` (plus `artist=`, wenn bekannt), nicht über die
  Freitextsuche `q=`: für „Higher Dimension" liefert `q=` 614 Treffer ohne die
  gesuchte Aufnahme auf der ersten Seite, `track=` hat sie auf Platz 3.
  Findet die Feldsuche nichts, läuft ein zweiter Versuch **ohne Artist** —
  Download-Seiten ersetzen Sonderzeichen im Dateinamen (aus „Ikøn" wird
  „IK N"), und über den Titel allein steht die Aufnahme trotzdem da. Für diese
  breite Suche gilt eine strengere Mindestpunktzahl (0.75).
- Bei Übereinstimmung gewinnt die **Schreibweise des Katalogs**: „Mama India
  Outside The (Universe Remix)" und „Mama India (Outside The Universe Remix)"
  sind für das Ähnlichkeitsmass identisch, aber nur eine gehört in den Tag.
- **Dauer-Abgleich ist der wichtigste Gegencheck** (±5 s bestätigt, >20 s
  wertet ab) — ohne ihn landet der Radio Edit als Extended Mix in den Tags.
  Discogs füllt `duration` aber nicht immer; dann kann der Schutz nicht
  greifen und der Vorschlag bleibt entsprechend niedriger bewertet.
- Lizenz: die genutzten Felder sind CC0, Bilder/Marktplatzdaten wären
  „Restricted Data" (nicht kommerziell) — für dieses Projekt unkritisch.
- **Sandbox:** die Mac-App braucht dafür `com.apple.security.network.client`.
  Das Entitlement fehlte zunächst (die App machte bis dahin keinen eigenen
  Outbound-HTTPS, Sparkle lädt über seinen XPC), und die Sandbox liess jede
  Anfrage auflaufen — im Sheet stand dann für jeden Track nur „Discogs nicht
  erreichbar". Der Grund steht jetzt im Klartext in der Statuszeile
  (`MetadataProposal.catalogErrorDescription`).

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
- **Discogs-Token im Klartext** in den App-Einstellungen (`UserDefaults`).
  Für einen Read-only-Token auf einen offenen Katalog vertretbar, gehört aber
  in den Keychain, sobald es eine Keychain-Schicht gibt.
- **Audio-Fingerprinting** als fünfte Stufe (ShazamKit nativ bzw.
  Chromaprint/AcoustID). Erkennt den Track am Klang statt am Namen und wäre
  damit die einzige Quelle, die bei völlig kryptischen Dateinamen trägt.
- **Kein ISRC/MBID** in den geschriebenen Tags — Discogs liefert keine, damit
  fehlt eine stabile Aufnahme-ID für späteres Re-Matching.
