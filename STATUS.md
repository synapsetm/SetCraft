# STATUS — SetCraft

Ergebnis-fokussierter Projektstand. Begleitend zu `CLAUDE.md` (Leitplanken)
und `SPEC.md` (Spezifikation und Phasenplan). Die frühere sitzungsweise
Chronologie ist bewusst entfernt — hier steht nur, was aktuell gilt.

Letzte Aktualisierung: 2026-09-21 (iOS 1.3-35 in TestFlight, Mac v1.3-17).

---

## Aktueller Stand

- **Phasen 0–5a komplett**, **Phase 5b (iOS-Target) voll umgesetzt**.
- **Mac-Release:** v1.3-17 (Build 17), notarisiert, Sparkle-Auto-Update live.
  Bringt den korrigierten Playhead (s. u.), Auto-Advance am Track-Ende,
  „copy to folder" im Kontextmenü samt erhaltener Selektion, die Ladeanzeige
  über der leeren Tabelle, den Swift-6-Sprachmodus und den Wiedergabe-Cache
  (der auf dem Mac nur bei gemounteten Netz-Volumes greift).
  v1.3-15 brachte die Tag-Ergänzung aus Dateinamen (vier Stufen, Review-Sheet,
  Discogs-Abgleich), das Löschen aus der Library, die DJ-Mix-Erkennung und die
  mitwachsende Waveform.
  v1.0-11 hatte einen Kaltstart-Bug (Öffnen aus dem Finder erzeugte kein
  Fenster, s. u.) und sollte übersprungen werden.
- **iOS-Release:** 1.3 (Build 35) in TestFlight, VALID; 34 ist abgelaufen.
  Der 20. September war ein Befund-Tag am Gerät; die Builds 18–27 sind die
  Kette daraus (Playhead, Flugmodus, Absturz beim Trackwechsel,
  Wiedergabe-Cache, Ladefortschritt — alle unter „Wichtige gelöste Probleme").
  Build 34 brachte den ersten Befund vom 21. September: der SMB-Share ist bei
  gesperrtem iPhone nicht neu aufbaubar, weil `smbclientd` nicht an den
  Keychain kommt (`SourceKeepAlive`, `ProtectedDataMonitor`, aufgeschobene
  Tag-Writes). **Build 35 korrigiert den `SourceKeepAlive` aus 34** — der
  zweite Testlauf desselben Tages zeigte, dass dessen Attribut-Abfrage die
  SMB-Session gar nicht erreicht (Details unter „Wichtige gelöste Probleme").
  Dazu die grössere Cache-Reichweite (9 statt 4 Dateien, ~45 statt ~20
  Minuten) und der Ladefehler des laufenden Tracks im Gerätelog.
  Build-Nummern der Plattformen laufen auseinander (iOS 35, Mac 17), weil
  iOS-Befunde eigene Builds bekommen. `scripts/asc-expire-builds.sh` lässt nach
  jedem Upload die älteren Builds ablaufen — Apple macht das nicht zuverlässig,
  und zwei installierbare Builds nebeneinander bedeuten Fehlermeldungen zu
  Ständen, die längst behoben sind.
- **Sprachmodus:** Swift 6 in der gesamten Codebasis — Core über
  `swift-tools-version: 6.0`, die App-Targets über `SWIFT_VERSION = 6.0`.
  Dazu `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` und
  `SWIFT_APPROACHABLE_CONCURRENCY`. Offen bleibt die Plattform-Untergrenze von
  `SetCraftCore` (`.macOS(.v14)` / `.iOS(.v17)`), die deutlich unter dem
  Deployment-Target der Apps (26.5) liegt und dort moderne APIs nur mit
  `#available` zugänglich macht.
- **Tests:** `swift test` im `SetCraftCore`-Paket grün — 233 Tests
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
- **In Ordner verschieben / kopieren** (macOS-Kontextmenü, Ordner-Auswahl per
  `NSOpenPanel`): Move macht same-volume ein atomares `moveItem`,
  cross-volume `copyItem` + `removeItem`; Copy lässt die Quelle stehen und
  braucht die Unterscheidung nicht. Beide überspringen Namenskonflikte am Ziel
  und melden sie gesammelt — bewusst kein stilles Umbenennen, eine Dublette in
  der Bibliothek ist schlimmer als eine klare Meldung. Auf iOS gibt es beides
  nicht.
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
- **Auto-Advance auf beiden Plattformen**: läuft ein Track natürlich aus, lädt
  der nächste in der **aktuell angezeigten Sortierung**. Am Listenende bleibt
  es stehen, es wird nicht von vorn begonnen. Der Hook (`onPlaybackEnded`) war
  bis 2026-09-19 nur auf iOS gesetzt — auf dem Mac blieb die Wiedergabe am
  Track-Ende einfach stehen. Auf dem Mac zieht die Tabellen-Selektion nur mit,
  wenn nichts oder genau der auslaufende Track ausgewählt war; eine
  Mehrfachauswahl für einen Massen-Tag-Write überlebt den Trackwechsel.
- iOS: Track-Load blockiert den MainActor nicht. Die Datei wird vorab auf
  einer eigenen Queue materialisiert (`AVAudioEnginePlayer.prefetch`), der
  nächste Track der Queue schon während der laufenden Wiedergabe. Relevant
  bei Quellen über FileProvider (iCloud, NAS/SMB via Files-App) — s. u.
- **Wiedergabe aus lokaler Kopie** (`PlaybackCache`): höchstens vier Dateien
  unter `Caches/playback/` — der laufende und die drei vorausgeholten Tracks. Damit
  ist der FileProvider aus dem Wiedergabe-Pfad heraus, und ein Netzverlust
  mitten im Track führt nicht mehr zu Stille bei laufendem Playhead. Kopiert
  wird nur, was nicht ohnehin lokal liegt (iOS: alles ausserhalb des
  App-Containers; macOS: nur Netz-Volumes).
- **Ladefortschritt** als echter Balken mit Prozentzahl: die Kopie läuft in
  256-KB-Häppchen, und jedes zurückkehrende Häppchen sind übertragene Bytes.
  Das ist die einzige verfügbare Fortschritts-Grösse — s. u.
- **Offline erkannt statt totgewartet**: ohne Netzpfad (`NWPathMonitor`) bricht
  der Load nach kurzer Gnadenfrist mit einer verständlichen Meldung ab, statt
  den Nutzer minutenlang auf einen Spinner schauen zu lassen. Eine *langsame*
  Quelle darf weiterhin beliebig lange brauchen — gemessen wird der Netzzustand,
  nicht die Dauer.

### Distribution
- macOS: `scripts/release.sh` — Build → Notarize → DMG → GitHub-Release →
  Sparkle-Appcast (`docs/appcast.xml`, GitHub Pages) in einem Lauf.
- iOS: `scripts/release-ios.sh` → TestFlight (ASC API Key), läuft ohne
  Organizer-Umweg durch. Einmalige Einrichtung der Signatur:
  `scripts/asc-setup-signing.sh`. Build-Status ohne Browser:
  `scripts/asc-status.sh`. Gemeinsame Auth in `scripts/asc-auth.sh`.
- **Lokalisierungs-Gate**: beide Release-Skripte rufen zwischen Archive und
  Export `scripts/check-localization.py --target macos|ios`. Ein fehlender
  deutscher String bricht den Release ab, bevor etwas notarisiert oder zu
  App Store Connect hochgeladen wird — beim iOS-Weg ist die Build-Nummer nach
  dem Upload verbrannt. Blockierend sind fehlende `de`-Einträge, schiefe
  Platzhalter, „ß", Keys ohne Katalogeintrag und abweichende Übersetzungen
  zwischen den Plattformen; Karteileichen und `de` == Key bei Einzelbegriffen
  („Album") bleiben Hinweise. `SKIP_L10N_CHECK=1` übergeht das Gate bewusst.
- About-Panel mit vollständigen Lizenz-Credits (GPL §6).
- Lokalisiert (EN + DE, Auto-Switch). Dark Mode als Default.

---

## Wichtige gelöste Probleme (Ergebnis-Referenz)

- **Blockierender Track-Load (iOS):** `AVAudioFile(forReading:)` kehrt bei
  einer Datei aus dem FileProvider erst zurück, wenn der Provider sie
  vollständig lokal materialisiert hat — bei iCloud wie bei einem NAS/SMB-Share
  aus der Files-App. `PlayerStore.load` rief das synchron auf dem MainActor:
  im Heim-WLAN unauffällig, über Mobilfunk/VPN mehrere Sekunden eingefrorene
  UI, bei jedem Tap und jedem Auto-Advance. Fix: `AVAudioEnginePlayer.prefetch`
  macht denselben Open vorab auf einer eigenen `DispatchQueue` (bewusst nicht
  auf dem Cooperative Pool — ein sekundenlang blockierter Thread gehört nicht
  in dessen enges Budget) und verwirft das Ergebnis; der Load danach trifft auf
  die lokale Kopie. `load()` bleibt synchroner Einstieg und startet einen Task,
  die Aufrufer ändern sich nicht. Schneller Track-Wechsel canceled den
  vorherigen Load, damit dessen spätes Ergebnis den neueren nicht überschreibt.
  `prefetchNeighbor()` holt den nächsten Track der `playbackQueue` im
  Hintergrund — das schliesst die Lücke beim Auto-Advance. Der alte
  iCloud-Sonderfall („gleich noch mal versuchen") entfällt; stattdessen zeigt
  die Library-Zeile einen Spinner.

  Nachtrag: die erste Fassung konnte sich selbst im Weg stehen. `cancel()` auf
  den Task brach nur das `await` ab, die Materialisierung lief weiter, und die
  Queue war `.concurrent` — zwanzig schnelle Skips starteten zwanzig parallele
  Voll-Downloads. Jetzt zwei **serielle** Queues, getrennt nach Dringlichkeit
  (`prefetch` userInitiated für den angetippten Track, `prefetchAhead` utility
  für die Vorausschau): höchstens zwei Downloads gleichzeitig, und die
  Spekulation steht dem Tap nie im Weg. Ein laufender Open lässt sich nicht
  unterbrechen — was das Abbruch-Flag rettet, ist die Warteschlange: wer
  abgehängt wurde, bevor er dran war, überträgt kein einziges Byte.
- **`AVAudioEngine.connect` als Absturzquelle:** Die klassische
  `connect(_:to:format:)` meldet ein Format, mit dem sie nichts anfangen kann,
  als Objective-C-Exception — Swift kann die nicht fangen, der Prozess stirbt.
  Bei einer Bibliothek aus fremden Dateien real. iOS/macOS 27 bietet dieselbe
  Verbindung mit `error:`; unter `#available` genutzt (Deployment-Target bleibt
  26.5), fällt ein unverdauliches Format ins `catch` des Aufrufers.
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
- **Automatische Analyse fehlte auf iOS komplett.** BPM- und Key-Chip blieben
  nach dem Abspielen bei „—". Keine Regression: `git log -S "analyze" --
  "SetCraft iOS/PlayerStore.swift"` findet keinen einzigen Treffer, der Aufruf
  wurde dort nie geschrieben. Analysiert wurde auf iOS ausschliesslich über die
  manuelle Aktion in der Bibliothek — während der Mac seit jeher
  `analyzeIfNeeded` im Lade-Pfad ruft. Damit verletzte die App eine Kernregel
  aus `CLAUDE.md` („Automatische BPM- und Key-Analyse beim Öffnen").
  `LibraryStore.analyzeIfNeeded` ist jetzt das Gegenstück, mit denselben Regeln
  wie auf dem Mac: DJ-Mixe aussen vor, und gerechnet wird nur, was fehlt
  (`analyze(trackID:force:)`). Gelesen wird aus der Wiedergabe-Kopie, damit die
  Analyse nicht am FileProvider hängt; geschrieben weiterhin in die Quelle.
- **Das Analyse-Ergebnis erreichte den Player nicht.** Nach der Analyse standen
  die Werte in der Liste, im Player weiter „—" — sichtbar erst nach einem
  Trackwechsel hin und zurück. `PlayerStore.currentTrack` ist eine **Kopie** vom
  Ladezeitpunkt; die Liste liest aus `library.tracks`, der Player aus seiner
  Kopie. Den Kanal gab es nur in der Gegenrichtung (`applyEdit`: Player →
  Library). Jetzt `LibraryStore.onTrackChanged`, und — der wichtigere Teil —
  `replaceInList` als **einziger** Weg, einen Track im Bestand zu ersetzen:
  vorher schrieben zwei Stellen direkt `tracks[idx] = …`, beim nächsten
  Schreibpfad wäre der Hook wieder vergessen worden. Betrifft nicht nur die
  Analyse, sondern auch Metadaten-Fix und Rating aus der Bibliothek.
- **Wettlauf zweier Prefetch-Queues.** Beim schnellen Durchskippen erschien
  häufig „The track could not be copied for playback". `prefetch`
  (audioLoadQueue) und `prefetchAhead` (audioLookaheadQueue) holen dabei oft
  DIESELBE Datei — der angetippte Track ist meist der, den die Vorausschau
  schon lädt. Beide sehen „Ziel existiert nicht", beide kopieren, der zweite
  `moveItem` scheitert am inzwischen vorhandenen Ziel. Kein Fehler: existiert
  das Ziel im `catch`, gilt der Lauf als erfolgreich.
- **Ein Cache-Problem durfte nie die Wiedergabe verhindern** — die Zusicherung
  stand im Kommentar über `store`, wurde beim Aufräumen aber gebrochen, weil
  jedes `nil` zum harten Ladefehler wurde. `store` liefert jetzt `StoreResult`
  mit drei Ausgängen, weil sie verschiedene Konsequenzen haben: `.cached` →
  aus der Kopie spielen; `.sourceIncomplete` → **nur das** bricht den Load ab
  (von einer halben Datei zu spielen ergibt Stille bei laufendem Playhead);
  `.cacheUnavailable` (Platte voll, Rechte) → von der Quelle spielen.
- **Folgetrack spielte nicht, rote Meldung stattdessen** („Failed to load
  track: … com.apple.coreaudio.avfaudio"). Getroffen hat es bevorzugt den
  Auto-Advance, und das ist kein Zufall: der Folgetrack kommt aus dem
  Prefetch, seine Wiedergabe-Kopie ist also die einzige, die zwischen Anlegen
  und Abspielen Zeit hat, kaputtzugehen. Ein einziger unbrauchbarer Puffer
  beendete damit die Wiedergabe, obwohl die Quelle in Ordnung war. Drei
  Ursachen zusammengekommen, alle behoben:
  - `store` legte die Kopie unter der **koordinierten** URL ab, gesucht wurde
    sie später unter der **Original**-URL. Weicht die koordinierte ab, findet
    `existingCopy` nie etwas und die Wiedergabe hängt wieder am FileProvider.
    `store` nimmt jetzt einen eigenen `cacheKey`.
  - Der einmalige Aufräumer für Reste der letzten Sitzung löschte auch die
    `staging-…`-Datei einer **gerade laufenden** Kopie der anderen Queue;
    deren `moveItem` lief danach ins Leere. Staging-Dateien bleiben jetzt
    unangetastet.
  - Liess sich die Kopie nicht öffnen, war Schluss. Jetzt wirft der Player
    `cachedCopyUnusable`, verwirft die Kopie, und der Aufrufer holt die Datei
    **einmal** neu (iOS über die Materialisierungs-Queue, nicht auf dem
    MainActor). Zweiter Fehlschlag wird gemeldet — ist die Quelle das Problem,
    hilft Wiederholen nicht. Eine 0-Byte-Kopie gilt zudem als nicht vorhanden.

  Nebenbefund aus demselben Screenshot: die rote Meldung blieb unter einem
  Track stehen, der längst wieder spielte (der Nutzer hatte nach dem
  gescheiterten Auto-Advance einfach Play gedrückt). Play/Pause räumt sie jetzt
  weg.
- **Waveform stand still, der Ton lief weiter (iOS).** Nach einem Ausflug in
  den Hintergrund nahm der `TimelineView(.periodic)`-Fahrplan manchmal nicht
  wieder auf. Die Wellenfläche blieb dann auf dem letzten Bild davor stehen —
  beim Auto-Advance also am **Ende des vorigen Tracks**, samt Zeitanzeige
  („7:53 / -0:00") und vollem Fortschrittsbalken —, während Titel, BPM, Key
  und der Play/Pause-Knopf (die an der Observation hängen, nicht am Fahrplan)
  längst den neuen Track zeigten. `WaveformTicker` hängt die Fläche jetzt an
  **beide** Taktgeber: 60-Hz-Fahrplan für die flüssige Zeichnung, plus die
  30-Hz-`position` aus der Engine als Observation-Abhängigkeit. Bleibt einer
  stehen, zeichnet der andere weiter. Der Fahrplan bekommt beim Rückkehr in
  den Vordergrund zusätzlich einen frischen Startzeitpunkt.
  **Reichte nicht** (in Build 31 ausgeliefert, am selben Nachmittag wieder
  aufgetreten): ein neuer Startzeitpunkt ändert den Fahrplan, nicht die
  Identität der `TimelineView` — der stehengebliebene Takt blieb. Seit Build 32
  hängt `epoch` zusätzlich an `.id()`, und ein **Track-Wechsel** setzt ihn
  ebenfalls neu: die Fläche wird dann samt Fahrplan neu aufgebaut. Der Zoom
  überlebt das (`@AppStorage`), der übrige View-Zustand ist flüchtig.
- **Der Auto-Advance ging am Wiedergabe-Cache vorbei — und damit über den
  FileProvider.** Befund am Gerät: läuft ein Track aus, während das iPhone
  gesperrt ist oder die App im Hintergrund läuft (Auto), endet der Folgetrack
  mit „Failed to load track: … com.apple.coreaudio.avfaudio". Per Next-Taste
  lädt derselbe Track sofort. Ursache ist keine kaputte Kopie: `attemptLoad`
  ruft **immer zuerst** `prefetch`, und `materialize` öffnet darin die Quelle
  über den FileProvider — bevor überhaupt jemand fragt, ob die fertige Kopie
  längst danebenliegt. Gesperrt bzw. im Hintergrund liefert der Provider nicht,
  und der Load scheiterte an einer Datei, die er gar nicht gebraucht hätte.
  Genau die Abhängigkeit, die der `PlaybackCache` beseitigen soll.
  `materialize` steigt jetzt bei vorhandener Kopie sofort aus (ein `stat`;
  eine Kopie entsteht nur aus einem vollständigen, byteweise gegengeprüften
  Durchlauf, halbe Dateien bleiben `staging-…`). Dazu: die Kopie wird
  ausdrücklich mit `completeUntilFirstUserAuthentication` angelegt — bei
  gesperrtem Gerät lesbar zu bleiben ist ihre Existenzberechtigung, nicht ein
  Nebeneffekt des Standardwerts. **Offen bleibt die Reichweite:** liefert der
  Provider im Hintergrund gar nicht, gelingt die Vorausschau dort auch nicht,
  und nach dem einen vorgeholten Track ist Schluss. Ob das so ist, steht beim
  nächsten Mal im Log — `prefetchAhead` schweigt nicht mehr, sondern schreibt
  jeden Fehlschlag mit Grund. **Reichweite erhöht** (Entscheid des Nutzers,
  2026-09-20): Vorausschau von einem auf **drei** Tracks, Cache-Kapazität
  entsprechend von zwei auf **vier** Dateien — laufender Track plus die drei
  nächsten. Die Kopien entstehen der Reihe nach auf der seriellen
  Lookahead-Queue, der nächste Track also zuerst; zwischen zwei Dateien greift
  der Abbruch, beim Durchskippen überträgt eine abgehängte Vorausschau darum
  keine ganze Datei mehr umsonst. Die LRU-Reihenfolge deckt sich damit genau:
  nach einem Lauf steht der laufende Track auf Platz vier und überlebt die
  Verdrängung, der zuletzt gespielte fliegt raus.

  **Die offene Frage ist am 2026-09-21 beantwortet** — und die Antwort lautet
  nicht „der Provider liefert im Hintergrund nicht", sondern: der Share war
  tot. Siehe den nächsten Eintrag; die Reichweite der Vorausschau war nie das
  eigentliche Problem.
- **Der Share ist bei gesperrtem iPhone nicht wieder aufbaubar — Ursache ist
  der Keychain, nicht der FileProvider.** Befund vom 2026-09-21: Set um 14:28
  gestartet, um 15:04 „The source could not be read while the iPhone was
  locked". Das Gerätelog zeigt die Kette vollständig:

  ```
  14:37:10  smbclientd  idleTimerFired: entering idle-disconnect
  14:37:13  smbclientd  Error retrieving item … Code=-25308
  14:37:13  smbclientd  connectToServer: unable to obtain credentials
  14:37:15  kernel      lock state change unlocked (0)
  14:37:15  smbclientd  checkServerConnection: successfully connected
  ```

  `-25308` ist `errSecInteractionNotAllowed`: die Zugangsdaten des Shares
  liegen im Keychain und sind bei gesperrtem Gerät nicht lesbar. Der
  Fehlschlag endet **in derselben Sekunde**, in der das Gerät entsperrt wird —
  eindeutiger wird eine Korrelation nicht. Jeder Zugriff danach quittiert mit
  `errno 80` (EAUTH), beim Nutzer sichtbar als
  `getattrlist = 80` (15:03:47) und `AVAudioFile … error 2003334207`
  (15:03:49).

  Getrennt hat die Session **der Idle-Timer von `smbclientd`**, nicht das
  Netz: gemessene 2:09, 2:01, ~2:00 zwischen letztem Zugriff und
  `idleTimerFired`. Ein sechsminütiger Track mit einminütiger Vorausschau
  reisst die Lücke bei jedem Track auf. Danach reicht die Wiedergabe genau so
  weit wie die vier Kopien im `PlaybackCache` — am 21.09. rund zwanzig
  Minuten (14:43 erster Fehlschlag, 15:03 Abbruch).

  Wichtig für die Einordnung: eine **bestehende** Session liefert auch bei
  gesperrtem Gerät. Nur der Neuaufbau scheitert. Die frühere Formulierung
  „gesperrt liefert der Provider nicht" war zu pauschal.

  Fix in zwei Teilen (Build 34):
  - `SourceKeepAlive` fragt einmal pro Minute die Attribute der laufenden
    Datei ab — derselbe `getattrlist`, den der FileProvider ohnehin macht; er
    geht bis zur SMB-Session durch und setzt deren Idle-Timer zurück. Eigene
    `DispatchQueue`. Bei lokalen Quellen ein No-op.
  - `ProtectedDataMonitor` meldet Sperren und Entsperren. Scheitert ein Load
    genau an der Sperre, holt der `PlayerStore` ihn beim Entsperren einmal
    nach — innerhalb von 15 Minuten, sonst finge die App nach einer im
    Hintergrund verbrachten Stunde beim Aufsperren an zu spielen. Ein
    eigener Eingriff (Play/Pause) sagt den Versuch ab.

  **Bleibt offen:** stirbt die TCP-Verbindung selbst (Mobilfunk-Handover,
  VPN-Wechsel — im Log vom 21.09. zweimal), braucht auch dieser Reconnect den
  Keychain und scheitert gesperrt. Dagegen hilft nur der `PlaybackCache`.
- **Build 34 hat nicht gewirkt — die Attribut-Abfrage erreicht die
  SMB-Session nicht.** Zweiter Test am 2026-09-21, 16:45–17:42, AirPods,
  iPhone die meiste Zeit gesperrt. Gerätearchiv über
  `sudo log collect --device-udid … --start …` gezogen.

  Der `SourceKeepAlive` meldete neunmal „Quelle erreichbar … (0.0s)" und kein
  einziges Mal „antwortet nicht" — auch in den Fenstern, in denen der Share
  nachweislich tot war (`-25308` → `connectToServer: unable to obtain
  credentials` → `checkServerConnection error: 80`, bei jedem Track-Wechsel
  ein Burst). Und `smbclientd: idleTimerFired` kam im selben Set **fünfmal**
  (16:48:20, 17:05:27, 17:06:37, 17:12:46, 17:13:09). `resourceValues` wird
  aus dem Metadaten-Cache des FileProviders beantwortet; die 0.0s sind das
  Indiz, der Idle-Disconnect der Beweis.

  Die Folge ist zweimal dieselbe Kette — Share stirbt, Wiedergabe läuft genau
  `capacity` Dateien weit, dann Stille bis zum Entsperren:

  | | erster Lauf | zweiter Lauf |
  |---|---|---|
  | Idle-Disconnect | 16:48:20 | 17:13:09 |
  | letzter Track aus dem Cache | 17:02:44 | 17:29:00 |
  | Stillstand | ~17:08 | 17:35:55 (`playbackRate 0.0`) |
  | Entsperrt → spielt wieder | 17:10:38 → 17:10:44 | 17:41:12 → 17:41:21 |

  Beide Male exakt **zwanzig Minuten** Reichweite. Der zweite Abbruch traf
  genau die Datei, die um 17:15:41, 17:21:30 und 17:29:04 nicht vorzuholen
  war (`20_crazy_box_…`) — und die um 17:41:21 dann sofort lief.

  **Der Doppeldruck auf den AirPods war nie das Problem.** Die beiden
  `MPSkipTrackCommandEvent` (Typ 4, NextTrack) um 17:10:13 und 17:10:19
  stehen im App-Prozess, der Handler quittiert `status=Success`. Es passierte
  nichts, weil der Zieltrack nicht ladbar war: Share tot, Cache leer. Kein
  Remote-Command-Problem.

  Ebenfalls ausgeschlossen: Bluetooth. Die A2DP-Latenzmeldungen laufen von
  16:46 bis 17:35 lückenlos durch, keine Route-Changes, keine Interruption.

  Was daraus folgte (Build 35):
  - `SourceKeepAlive` macht jetzt einen **echten Lesezugriff** — `open`, ein
    Byte von wanderndem Offset, `close`, Handle mit `F_NOCACHE`. Erst der
    `open` löst den `LIAccessCheck` des LiveFS-Providers aus. Ob das reicht,
    entscheidet das nächste Archiv: bleibt `idleTimerFired` während eines
    Sets aus, hat es gewirkt — sonst ist der nächste Kandidat eine
    Verzeichnis-Enumeration. Deshalb steht jeder Tick im Log, nicht nur der
    Wechsel.
  - Vorausschau 3 → **8**, `PlaybackCache`-Kapazität 4 → **9**: rund
    fünfundvierzig Minuten Reichweite statt zwanzig. Symptombekämpfung, aber
    unabhängig davon wirksam, ob der Wach-Lesezugriff durchkommt.
  - Der Ladefehler des **laufenden** Tracks steht jetzt auf `.error` im
    Gerätelog. Er fehlte komplett; nur die Vorausschau meldete sich. `log
    collect` behält ohnehin nur `default` und `error` — die `.debug`-Zeilen
    des `PlaybackCache` tauchen im Archiv gar nicht erst auf.
  - `center.playbackState` auf iOS entfernt: das Log quittiert jeden Aufruf
    mit „Ignoring setPlaybackState because application does not contain
    entitlement". Massgeblich ist `MPNowPlayingInfoPropertyPlaybackRate`.
- **Tag-Writes bei gesperrtem Gerät liefen in den In-place-Fallback.** Derselbe
  Nachmittag, dreimal dieselbe Kette: `copyItem failed … errno=80 — falling
  back`, danach `In-place write failed … File is not writable`. Der
  Sibling-Temp scheitert an der toten Session, und `TagLibTrackStore`
  eskaliert daraufhin auf den **nicht-atomaren** Write direkt auf die
  Originaldatei — der Fallback ist für abweisende SMB-ACLs gedacht, nicht für
  eine Verbindung, die nachweislich kaputt ist. `save` prüft deshalb vorher
  den `ProtectedDataMonitor` und wirft `.deviceLocked`, bevor irgendetwas
  angefasst wird; nur für Quellen hinter einem FileProvider bzw. auf einem
  Netz-Volume (dieselbe Unterscheidung wie im `PlaybackCache`), auf macOS
  greift der Riegel nie. `.deviceLocked` ist wie `.fileInUse` kein Fehler,
  sondern ein „später" (`StoreError.isDeferrable`) — geparkt in
  `pendingSaves`, nachgeholt beim Entsperren. Betroffen ist vor allem die
  Auto-Analyse, die bei jedem Track-Load läuft.
- **FileProvider liefert sequenziell — und ein Read wartet bis zu seiner
  Stelle.** Die zentrale Erkenntnis des 2026-09-20, am Gerät über Mobilfunk
  gemessen (vier Tracks, Zeiten in Sekunden):

  | open | head (0 %) | mid (50 %) | tail (100 %) | copy |
  |---|---|---|---|---|
  | 0.6 | 0.0 | 8.3 | 8.3 | 0.4 |
  | 0.0 | 0.0 | 6.0 | 9.0 | 0.5 |
  | 0.3 | 0.1 | 6.2 | 6.3 | 0.2 |
  | 0.2 | 0.0 | 0.0 | 6.1 | 0.5 |

  `AVAudioFile(forReading:)` lädt **nichts** herunter — es liest den Kopf und
  kehrt sofort zurück. Der Download beginnt mit dem ersten Read jenseits des
  bereits Vorhandenen und läuft von vorne durch; jeder Read blockiert, bis der
  Download seine Stelle erreicht hat. Dass Mitte *und* Ende je 6–9 s brauchen,
  schliesst „alles-oder-nichts" aus; dass die Kopie danach nur 0.2–0.5 s
  dauert, zeigt, dass dann alles lokal liegt.

  Damit ist der ursprüngliche „Track läuft, aber kein Ton"-Befund vollständig
  erklärt: die Wiedergabe startete auf dem Kopf, und die Engine-Reads liefen in
  Daten, die noch nicht da waren. Und es ist der Grund, warum der
  Ladefortschritt aus einer **eigenen** häppchenweisen Kopie kommt:
  `totalFileAllocatedSize` steht von Anfang an auf 100 %, das Dateisystem gibt
  über den Fortschritt nichts preis.
- **Stille statt Fehlermeldung im Flugmodus:** `materialize` bekam eine
  `NSError`-Adresse, die niemand auslas, und der Open stand unter `try?` —
  beide Fehlerquellen wurden verschluckt. Die Engine bekam die Datei trotzdem,
  spielte sichtbar los und blieb stumm. Jetzt meldet `materialize` eine
  Begründung, `prefetch` wirft, und der Load bricht **mit** Meldung ab.
  `AudioEngineError` ist `LocalizedError`, aber bewusst **nicht** lokalisiert:
  der Core ist ein Package ohne `defaultLocalization` und ohne Katalog, Keys
  dort erfasst keiner der beiden App-Kataloge. Übersetzt wird in der UI-Schicht.
- **Absturz beim Trackwechsel (iOS, Swift 6):** `MPMediaItemArtwork` ruft seinen
  Request-Handler auf einer eigenen Queue auf — beim Zusammenbauen des
  Now-Playing-Dictionaries, also bei jedem Trackwechsel. Der Handler-Typ ist
  nicht `@Sendable`; im `@MainActor`-`NowPlayingManager` gebildet erbt er dessen
  Isolation, und im Swift-6-Sprachmodus prüft die Runtime das beim Aufruf
  (`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue`). Die Prüfung
  schlägt fehl: `EXC_BREAKPOINT`. Die Umstellung auf Swift 6 hat das scharf
  gemacht. Fix: das Artwork in einer `nonisolated` Funktion bauen. **Die
  Fehlerklasse gilt allgemein** — ein nicht-`@Sendable`-Callback, der in einem
  isolierten Kontext gebildet und vom Framework auf fremder Queue gerufen wird,
  ist unter Swift 6 ein Absturz, kein Warnung.
- **Hänger im Waveform-Draw:** die Beat-Grid-Schleife war unbeschränkt
  (`while true`, Abbruch nur über `x > width`). Ein BPM-Tag mit dem Text `inf`
  macht `bar` zu 0 und `t` zu NaN — jeder Vergleich mit NaN ist false, die
  Schleife bricht nie ab; bei `1e300` ist `bar` subnormal und `t += bar` bewegt
  `t` nicht mehr. Harter Hänger auf dem Main-Thread. `TagReader.sanitizedBPM`
  lässt solche Werte nicht mehr ins Modell (endlich, > 0, ≤ 500), und beide
  Schleifen iterieren über einen Index statt über einen Float-Akkumulator.
- **Drei blockierende Datei-Aufrufe auf dem MainActor**, alle derselben Art —
  eine harmlos aussehende Metadaten- oder Listing-Abfrage, die bei einer
  FileProvider-URL zum Provider geht und ohne Netz nicht zurückkehrt:
  `PlayerStore.performLoad` fragte Resource-Values **vor** dem ersten `await`
  ab (UI fror beim Trackwechsel komplett ein, Spinner inklusive);
  `LibraryRepository.scan` rief `FolderScanner.collect` synchron, bevor der
  Stream existierte (App-Start mit Netz-Quelle fror ein — beide Plattformen,
  weil die App-Targets mit `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` laufen
  und der `Task` die Isolation erbt); und `AVAudioFile(forReading:)` beim
  Track-Load war der erste dieser Reihe (2026-09-18). Merksatz: **jede
  Datei-API kann bei einer Provider-Quelle blockieren**, auch die, die nur
  Metadaten liest.
- **Copy/Move warfen die Selektion weg:** ein Refresh nach dem Kopieren, mit der
  Begründung „lässt sich nicht sicher sagen, und ein Refresh ist billig". Beides
  falsch — das Ziel lässt sich mit `folderURL` vergleichen, und ein Refresh
  kostet Selektion, Scroll-Position und seit dem Listing-Umbau eine komplette
  Neu-Auflistung. Copy scannt jetzt nur noch, wenn das Ziel die angezeigte
  Quelle ist; Move nimmt die Zeilen direkt aus der Liste und rückt die Selektion
  nach. `scan` rettet die Selektion zusätzlich über URLs — `Track.id` wird bei
  jedem Scan neu vergeben.
- **Playhead-Sync (Mac + iOS):** Waveform-Progress auf Wave-Zeitachse statt
  `player.duration`, Spalten-Aggregation per Float-Division — beides gegen
  wachsenden Drift. Die **Latenz-Korrektur war bis 2026-09-19 falsch** und ist
  jetzt gemessen statt vermutet (`AVAudioEnginePlayer.audiblePosition()`):
  - `lastRenderTime.hostTime` ist **nicht** der Moment des Renderns, sondern die
    anvisierte Ausgabezeit des Buffers — auf macOS konstant **14–22 ms in der
    Zukunft**. Der alte Code klammerte `now − hostTime` auf `0`; die ganze
    Drift-Korrektur war damit toter Code, der Zweig traf während der Wiedergabe
    nie zu.
  - Das Vorzeichen war verdreht: Sample `S` ist erst bei
    `hostTime + outputPresentationLatency` hörbar, die Latenz muss also
    **abgezogen** werden. Addiert schob sie die Anzeige um den doppelten Betrag
    nach vorn — der Mac lief ~210 ms voraus, iOS (roher `position`-Wert ohne
    jede Korrektur) ~110 ms plus die Bluetooth-Funkstrecke.
  - Gegenprobe: die hörbare Position darf die Wanduhr seit `play()` nie
    überschreiten. Alte Formel lag **+60…+72 ms darüber** (unmöglich), neue
    konstant −141 ms darunter = die Anlauf-Strecke (TimePitch 93 ms + HW-Buffer).
  - Gemessene Latenzen: `playerNode.outputPresentationLatency` = **94 ms**
    (TimePitch 93 + HW 1,3). Der Kommentar „~203 ms Hardware-Buffer" war
    erfunden; `outputNode.outputPresentationLatency` ist **1,3 ms** und kennt
    die TimePitch-Latenz nicht — darum bleibt der PlayerNode die richtige Quelle.
  - Auf iOS zusätzlich `max(nodeLatency, session.outputLatency +
    ioBufferDuration + timePitch.latency)`: über Bluetooth liegen 150–200 ms
    Funkstrecke, die die `AVAudioSession` ausweist. Maximum statt Summe, weil
    beide dieselbe Strecke schätzen.
  - `position` (30-Hz-Timer) rechnet jetzt dieselbe Korrektur, damit Zeitanzeige,
    Mini-Player und Now-Playing mitkommen; die iOS-Waveform liest `livePosition`
    in einer 60-Hz-`TimelineView` wie der Mac. `pause()` merkt sich die hörbare
    statt der gerenderten Position — sonst übersprang „Weiter" den gepufferten
    Vorlauf, den `playerNode.stop()` verwirft.
  - **Am Gerät bestätigt** (1.3-18, 2026-09-19): synchron über AirPlay *und*
    lokale Ausgabe, Pause/Weiter ohne Sprung. Dass AirPlay stimmt, ist der
    Beleg für die `max()`-Konstruktion: die Funkstrecke kennt dort nur die
    `AVAudioSession`, nicht der Node.
- **MP3-Decode-Fallback:** `AVAudioFile` wirft bei manchen MP3-Headern
  `_GenericObjCError 0` → `AVAssetReader`-Fallback (CoreMedia-Decoder,
  native Sample-Rate, kein Resampling).
- **Aktiver Track:** Schreibvorgänge auf die im Player offene Datei werden mit
  `StoreError.fileInUse` abgelehnt, in `pendingSaves` geparkt und beim
  Track-Wechsel nachgeholt (Mac + iOS). iOS flusht zusätzlich bei
  `scenePhase == .background` und beim Entsperren (`drainPendingSaves`, seit
  Build 34 auch für `.deviceLocked`). Alle vier Schreibpfade des iOS-
  `LibraryStore` gehen durch `persistOrPark` — vorher nahmen
  `setActiveTrack` und `flushPendingSaves` den Eintrag **vor** dem
  Schreibversuch aus der Queue, ein erneut verschobener Save war damit weg.
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
- **`.stringsdata` sind flüchtig**: ein `clean` des einen Targets räumt die
  Daten des anderen mit weg, und Release-Builds legen woanders ab als Debug.
  Wer das nicht bedenkt, bekommt vom Lokalisierungs-Check reihenweise falsche
  Karteileichen gemeldet. `check-localization.py` sucht die Daten deshalb
  selbst über alle Konfigurationen und bricht ab, wenn sie älter sind als die
  Quellen — statt einen veralteten Stand als sauber zu melden.
- Sparkle-CLI (`generate_keys`, `generate_appcast`) liegt in DerivedData; für
  `release.sh` ggf. `SPARKLE_BIN_DIR` explizit setzen.
- Nach jedem Build/Release-Lauf registriert LaunchServices die Kopien aus
  `build/release/` und DerivedData unter derselben Bundle-ID — ein Doppelklick
  im Finder kann dann eine Artefakt-Kopie statt `/Applications/SetCraft.app`
  starten. Prüfen mit `lsregister -dump | grep SetCraft.app`, aufräumen mit
  `lsregister -u <pfad>` und `lsregister -f -R /Applications/SetCraft.app`.
  Welche Version wirklich läuft: About-Panel bzw.
  `ps -p $(pgrep -x SetCraft) -o comm=`.
- **Das L10n-Gate lief auf Zufallsdaten.** Der Suchpfad kannte nur normale
  Builds (`Build/Intermediates.noindex/SetCraft.build`); ein Archive legt seine
  Intermediates unter `ArchiveIntermediates/<Scheme>/IntermediateBuildFilesPath/`
  ab. Beide Release-Skripte prüfen zwischen Archive und Export — das Gate sah
  also nie das Archive, das es absichert, sondern Reste des letzten normalen
  Builds. Aufgefallen erst, als ein `clean` des anderen Targets gar nichts mehr
  übrig liess. Seit 2026-09-19 werden beide Orte durchsucht.
- **`errSecInternalComponent` beim iOS-Export**: `exportArchive` scheitert beim
  Signieren, ohne dass am Code etwas falsch wäre. **Ursache ist der
  Schlüsselbund-Dialog**, der nach dem Zugriff auf den privaten Schlüssel des
  Distribution-Zertifikats fragt — wird er abgebrochen oder weggeklickt,
  scheitert der Export mit genau diesem Code. Am 2026-09-20 dreimal
  hintereinander so passiert. Richtige Antwort ist „**Immer erlauben**", nicht
  „Lauf wiederholen": ohne das kommt die Rückfrage bei jedem Release wieder.
  Hochgeladen wird dabei nichts, die Build-Nummer bleibt frei.
- **TestFlight-Builds ablaufen lassen**: `scripts/asc-expire-builds.sh` setzt
  alles ausser dem neuesten VALID-Build auf `expired`. Apple räumt nicht
  zuverlässig auf — am 2026-09-20 standen 21 und 19 gleichzeitig aktiv, während
  20 und 18 abgelaufen waren. Sicherheitsregel: ist der neueste Build noch in
  Verarbeitung, bricht das Skript ab, statt die älteren wegzuräumen; sonst
  bliebe für die Dauer der Verarbeitung nichts Installierbares.
- Build-Status ohne Browser: `scripts/asc-status.sh` (App Store Connect API,
  ES256-JWT über `openssl`, weil PyJWT/`cryptography` nicht installiert sind).
  Zeigt Verarbeitungsstand, Ablauf und ob der Build ein Icon trägt.
  Das graue Platzhalter-Icon in der ASC-Kopfzeile kommt daher, dass an der
  App-Store-Version 1.0 (PREPARE_FOR_SUBMISSION) kein Build hängt — bei reiner
  TestFlight-Verteilung normal, kein Build-Fehler.
- iOS-TestFlight: Der Cloud-Signing-Abbruch ist **behoben** (2026-09-18).
  Ursache war kein sprunghaftes Verhalten, sondern eine fehlende Identität:
  lokal existierte nur „Apple Development" und „Developer ID Application",
  also wich `exportArchive` auf Cloud-Signing aus — und dafür hat der
  ASC-API-Key die falsche Rolle. `scripts/asc-setup-signing.sh` legt jetzt
  Apple-Distribution-Zertifikat und passendes App-Store-Profil an (idempotent,
  `--list` zeigt nur den Ist-Zustand); `ExportOptions-iOS.plist` signiert
  manuell dagegen. Der Organizer-Umweg entfällt. Nebenbefund: ein reguläres
  Distribution-Zertifikat darf der Key sehr wohl anlegen — die Rollenprüfung
  greift nur bei den *cloud-managed*. Zertifikat und Profil laufen
  2027-09-18 ab. Details in `docs/DISTRIBUTION.md` §8.1.
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

### Unmittelbar — Verifikation zu Build 35

- **Wirkt der Wach-Lesezugriff?** Unbeantwortet, bis ein Gerätelog eines
  echten Sets vorliegt. Die Entscheidungszeile ist `smbclientd:
  idleTimerFired` — bleibt sie während des Sets aus, hat der `open` die
  SMB-Session erreicht; taucht sie weiter auf, ist der nächste Kandidat eine
  Verzeichnis-Enumeration statt des Ein-Byte-Lesezugriffs. Vergleichbar wird
  es nur unter denselben Bedingungen wie am 21.09.: AirPods, iPhone gesperrt
  in der Tasche, NAS über VPN.

  Auslesen (der `sudo`-Prompt braucht ein echtes Terminal, nicht die
  Claude-Session):

  ```sh
  sudo /usr/bin/log collect --device-udid <UDID> \
      --start "<JJJJ-MM-TT HH:MM:SS>" --output ios-test.logarchive
  ```

  Im Archiv zählen drei Muster: `idleTimerFired` (s. o.),
  `SourceKeepAlive: Wach-Lesezugriff` (einer pro Minute; eine Dauer über 0.0s
  heisst, der Aufruf ging bis zum Server) und `PlayerStore: Load gescheitert`
  (neu — der Abbruch des laufenden Tracks samt Sperrzustand).
- **Mac-Klick-Test zu Build 35 steht aus.** Der `PlaybackCache` ist geteilter
  Core-Code, und seine Kapazität hat sich mit Build 35 von 4 auf 9 geändert;
  auf dem Mac greift er bei gemounteten Netz-Volumes. Zu prüfen: Track laden,
  abspielen, mehrfach skippen. Bewusst **nicht** vor dem iOS-Testlauf
  gemacht (Entscheid des Nutzers, 2026-09-21): für den Mac steht kein Release
  an, und der Code wird nach der Auswertung ohnehin wieder angefasst.
  Es gibt keine Test-Suite für die Apps — der Klick-Test ist die einzige
  Absicherung.

### Features und Altlasten

- **iCloud-Sync der Library** zwischen Mac und iPhone (App Group + CloudKit).
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
- **Früher hörbarer Ton bei Netz-Quellen** — bewusst offen. Machbar wäre es:
  der Provider liefert sequenziell, man könnte mit eigenen Puffern abspielen,
  während der Download läuft (`AVAudioFile` kann das nicht, es legt die Länge
  beim Öffnen fest). Der Preis: beim ERSTEN Abspielen hinge der Track wieder am
  Netz, und genau die Ausfallsicherheit, die der Wiedergabe-Cache bringt, gälte
  erst ab dem zweiten Mal. Für einen DJ-Einsatz ist ein Aussetzer mitten im
  Track schlimmer als acht Sekunden Warten — deshalb vorerst nicht gebaut.
- **Audio-Fingerprinting** als fünfte Stufe (ShazamKit nativ bzw.
  Chromaprint/AcoustID). Erkennt den Track am Klang statt am Namen und wäre
  damit die einzige Quelle, die bei völlig kryptischen Dateinamen trägt.
- **Kein ISRC/MBID** in den geschriebenen Tags — Discogs liefert keine, damit
  fehlt eine stabile Aufnahme-ID für späteres Re-Matching.
