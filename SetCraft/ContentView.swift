import SwiftUI
import SetCraftCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var player: PlayerViewModel
    @Bindable var library: LibraryViewModel
    @Bindable var transport: TransportViewModel
    @Bindable var waveform: WaveformViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            hairline
            nowPlaying
            hairline
            waveformRow
            hairline
            transportBar
            hairline
            LibraryView(library: library,
                        loadingURL: player.loadingURL,
                        currentURL: player.player.loadedURL,
                        isPlaying: player.player.isPlaying) { track in
                player.loadTrack(track)
                library.analyzeIfNeeded(track)
                library.notePlay(forURL: track.url)
            }
        }
        // 960 statt 760: das Now-Playing-Raster braucht für vier Readouts
        // plus eine lesbare TRACK-Spalte etwa diese Breite. 640 hoch: Player
        // (Raster, 148er-Waveform, Transport) plus Toolbar und Footer belegen
        // gut 450 pt — darunter blieb kaum Tabelle, und der Footer wurde
        // unten abgeschnitten.
        .frame(minWidth: 960, minHeight: 640)
        .background(Theme.Palette.background)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // Gleicher Weg wie beim Öffnen aus dem Finder: abspielen und den
            // Track in der Library sichtbar machen.
            openExternalFile(url)
            return true
        }
        .onChange(of: player.player.loadedURL, initial: true) { _, newURL in
            // Track-Datei nicht beschreiben, solange AVAudioEngine sie hält.
            library.setActiveTrack(newURL)
            // Master-Werte auf den neu geladenen Track anwenden.
            transport.applyMasterToLoadedTrack()
            // Waveform für den neuen Track im Hintergrund laden.
            waveform.setActiveURL(newURL)
        }
        // Anzeige der klingenden Tonarten hängt am Wiedergabezustand — hier
        // gespiegelt, damit die Bibliothek nicht den Player kennen muss.
        .onChange(of: transport.soundingContext, initial: true) { _, context in
            library.soundingContext = context
        }
        .onAppear {
            // Wird die Library-Analyse für den aktuell geladenen Track
            // fertig, holen wir die frischen Original-Werte ab und legen
            // sie als Player-Baseline an (damit die Chips sie anzeigen).
            library.onTrackAnalyzed = { [weak player, transport] track in
                guard let player, player.player.loadedURL == track.url else { return }
                player.originalBPM = track.bpm
                player.originalKey = track.key
                transport.applyMasterToLoadedTrack()
            }
            // Auto-Advance: läuft ein Track natürlich aus, den nächsten in der
            // aktuell angezeigten Sortierung laden — wie auf iOS. Der Hook war
            // bisher nur dort gesetzt, auf dem Mac blieb die Wiedergabe am
            // Track-Ende einfach stehen.
            //
            // `nextTrack(after:)` liefert am Listenende `nil`; dann bleibt es
            // stehen, statt von vorn zu beginnen. Die Selektion zieht nur mit,
            // wenn genau der auslaufende Track ausgewählt war — sonst würde
            // eine Mehrfachauswahl mitten in der Arbeit verschwinden.
            player.player.onPlaybackEnded = { [weak player, library] in
                guard let player,
                      let finishedURL = player.player.loadedURL,
                      let next = library.nextTrack(after: finishedURL)
                else { return }
                // „Verfolgt" heisst: nichts ausgewählt, oder genau der Track,
                // der gerade ausgelaufen ist. Eine Auswahl auf einem anderen
                // Track gehört einer anderen Absicht und bleibt unangetastet.
                let selected = library.selectedTrackIDs
                let finishedID = library.tracks.first(where: { $0.url == finishedURL })?.id
                let wasFollowing = selected.isEmpty
                    || (selected.count == 1 && selected.first == finishedID)
                Self.loadIntoPlayer(
                    next,
                    player: player,
                    library: library,
                    moveSelection: wasFollowing
                )
            }
            library.restoreSavedFolders()
            // Dateien aus dem Finder laufen über den AppDelegate statt über
            // `.onOpenURL` — sonst öffnet SwiftUI pro Datei ein neues Fenster.
            // Beim Kaltstart gepufferte URLs werden hier direkt nachgereicht.
            AppDelegate.setOpenFileHandler { url in
                openExternalFile(url)
            }
        }
    }

    // MARK: - Header + Now Playing

    private var hairline: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(height: 1)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(width: 1)
    }

    /// Kopfzeile: Marke links, aktive Quelle und Anzahl Tracks rechts.
    private var appHeader: some View {
        HStack(spacing: 0) {
            Text(verbatim: "SETCRAFT")
                .font(Theme.Typo.brand)
                .tracking(Theme.Typo.brandTracking)
                .foregroundStyle(Theme.Palette.accent)
            Spacer()
            if let sourceName {
                HStack(spacing: 0) {
                    Text(verbatim: "\(sourceName) · ")
                    Text("\(library.tracks.count) tracks")
                }
                .themeLabel()
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 40)
    }

    /// Name der aktiven Quelle — wie in der Quellen-Liste, sonst der Pfad.
    private var sourceName: String? {
        if let id = library.selectedFolderID,
           let folder = library.folders.first(where: { $0.id == id }) {
            return folder.name
        }
        return library.sourceURL?.lastPathComponent
    }

    /// Raster unter der Kopfzeile, sechs gleich breite Spalten wie im
    /// Mockup: TRACK (mit Artwork, zwei Spalten) · BPM · KEY · ELAPSED · REMAIN.
    private var nowPlaying: some View {
        WeightedColumns {
            trackCell
                .nowPlayingCell()
                .layoutWeight(2)
            // Zellen-Innenabstand setzt der Chip selbst — die Hover-Fläche
            // soll die ganze Zelle füllen, nicht nur den Inhalt.
            TempoChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
                .overlay(alignment: .leading) { columnDivider }
            KeyChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
                .nowPlayingCell()
                .overlay(alignment: .leading) { columnDivider }
            timeCell("Elapsed") { elapsed, _ in
                (formatTime(TimeInterval(elapsed)), Theme.Palette.text)
            }
            timeCell("Remain") { elapsed, total in
                ("-" + formatTime(TimeInterval(max(0, total - elapsed))), Theme.Palette.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var trackCell: some View {
        HStack(spacing: 14) {
            ArtworkView(url: player.player.loadedURL, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Track").themeLabel()
                Text(titleLine)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(artistLine)
                    .font(Theme.Typo.artist)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// ELAPSED/REMAIN. Beide rechnen mit derselben ganzen Sekunde
    /// (`elapsed`, abgerundet) und REMAIN = Gesamtlänge − ELAPSED — so
    /// springen sie immer im selben Moment um. Einzeln gerundet lagen die
    /// Wechsel um den Nachkommaanteil der Tracklänge auseinander.
    ///
    /// Der 0,1-s-Takt hält den Sprung nah an der echten Sekundengrenze; neu
    /// gezeichnet wird der Text nur, wenn sich der Wert ändert. Gelesen wird
    /// `livePosition` (frisch aus `lastRenderTime`), nicht die
    /// @Observable-`position`.
    private func timeCell(
        _ label: LocalizedStringKey,
        value: @escaping (_ elapsed: Int, _ total: Int) -> (String, Color)
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let dur = player.player.duration
            let total = dur.isFinite && dur > 0 ? Int(dur.rounded()) : 0
            let pos = player.player.livePosition
            let elapsed = pos.isFinite ? min(total, max(0, Int(pos))) : 0
            let (text, color) = value(elapsed, total)
            VStack(alignment: .leading, spacing: 6) {
                Text(label).themeLabel()
                Text(verbatim: text)
                    .font(Theme.Typo.readout)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(player.player.loadedURL == nil ? Theme.Palette.textMuted : color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .nowPlayingCell()
        .overlay(alignment: .leading) { columnDivider }
    }

    // MARK: - Player

    private var waveformRow: some View {
        ZStack(alignment: .topLeading) {
            // Expliziter 60-Hz-Periodic-Schedule statt `.animation` — letztere
            // ist auf macOS unzuverlässig: ohne aktive SwiftUI-Animation tickt
            // sie nicht, der Playhead bliebe stehen. Periodic erzwingt den
            // re-eval, damit `livePosition` frisch aus `lastRenderTime`
            // gezogen wird und der Cursor synchron zum hörbaren Audio läuft.
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
                WaveformView(
                    data: waveform.data,
                    progress: liveWaveformProgress,
                    onSeek: { fraction in
                        let duration = max(player.player.duration, 0.01)
                        player.seek(to: fraction * duration)
                    },
                    onScrub: { fractionDelta in
                        // Mausrad-Tick: Sprungweite ~ Track-Position +
                        // (Delta × Track-Länge × Sensitivity-Faktor).
                        // Faktor 0.5 macht eine volle Drehung über die ganze
                        // Waveform-Breite ≈ 50 % des Tracks lang.
                        let duration = player.player.duration
                        guard duration > 0 else { return }
                        let current = player.player.position
                        let target = current + fractionDelta * duration * 0.5
                        player.seek(to: max(0, min(duration, target)))
                    }
                )
            }
            // Als `.overlay`, nicht als weiteres ZStack-Kind: ein Overlay
            // übernimmt die Grösse der Waveform. Als Geschwister hätte das
            // `maxHeight: .infinity` den Stack nach unten aufgezogen, und der
            // Balken landete unterhalb der Welle.
            .overlay {
                if player.loadingURL != nil {
                    trackLoadOverlay
                }
            }
            // Während des Track-Loads gehört die Fläche dem Overlay.
            if player.loadingURL == nil, waveform.isLoading {
                HStack(spacing: 6) {
                    // Sobald die ersten Bins da sind, zeigt der Balken den
                    // Fortschritt — die Welle wächst ja sichtbar mit.
                    if let partial = waveform.data, !partial.bins.isEmpty, !partial.isComplete {
                        ProgressView(value: partial.completion)
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Analyzing waveform…")
                        .themeLabel()
                }
                .padding(8)
            } else if player.loadingURL == nil, let error = waveform.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.keyAmbiguous)
                    .lineLimit(1)
                    .padding(8)
            }
        }
    }

    /// Ladeanzeige über der Waveform, solange der Player einen Track holt —
    /// wie `WaveformCanvasView.trackLoadOverlay` auf iOS. Bei einer NAS-
    /// Quelle mit Fortschritt aus der Cache-Kopie, sonst nur Spinner. Der
    /// Blick liegt beim Laden ohnehin auf der Welle.
    private var trackLoadOverlay: some View {
        VStack(spacing: 8) {
            if let fraction = player.loadProgress {
                ProgressView(value: fraction)
                    .tint(Theme.Palette.accent)
                    .frame(width: 220)
                Text(verbatim: "\(Int(fraction * 100)) %")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.waveformBG.opacity(0.75))
        .allowsHitTesting(false)
    }

    private var liveWaveformProgress: Double {
        // KRITISCH: Progress muss auf die ZEITACHSE DER WAVEFORM bezogen werden,
        // nicht auf player.duration. Die WaveformView verteilt ihre Bins linear
        // über die volle View-Breite — `x = width` entspricht damit
        // `bins.count × secondsPerBin` Sekunden. Wenn diese Dauer von
        // `player.duration` (aus AVAudioFile.length) abweicht — z. B. weil
        // VBR-MP3-Header eine Schätzung statt exakter Frame-Zahl liefern —
        // läuft der Playhead sonst linear schneller oder langsamer durch
        // die Wave als das hörbare Audio. Drift wird minutenlang sichtbar.
        let waveDuration = waveformDuration
        let effectiveDuration = waveDuration > 0 ? waveDuration : player.player.duration
        guard effectiveDuration > 0 else { return 0 }
        return max(0, min(1, player.player.livePosition / effectiveDuration))
    }

    private var waveformDuration: Double {
        guard let w = waveform.data else { return 0 }
        // `totalSeconds` nimmt während der laufenden Analyse die geschätzte
        // Gesamtlänge — sonst würde der Playhead am rechten Rand kleben und
        // bei jedem Zwischenstand zurückspringen, weil die Welle noch wächst.
        return w.totalSeconds
    }

    /// Sterne-Rating für den aktuell geladenen Track. Gedimmt + Tap
    /// deaktiviert, sobald der Track nicht in der Library steht (ohne
    /// `Track`-Eintrag fehlt das Persistenz-Ziel).
    @ViewBuilder
    private var ratingStars: some View {
        let editable = loadedTrack != nil
        StarRatingView(rating: loadedTrack?.rating ?? .none, size: 17) { newRating in
            guard let url = player.player.loadedURL else { return }
            library.setRating(forURL: url, newRating)
        }
        .disabled(!editable)
        .opacity(editable ? 1.0 : 0.45)
        .help(editable ? "Rating" : "Track is not in the library — rating can't be saved")
    }

    /// Track gerade im Player — falls in der Library bekannt, holen wir
    /// Titel und Artist daraus. Sonst Fallback auf den Dateinamen.
    private var loadedTrack: Track? {
        guard let url = player.player.loadedURL else { return nil }
        return library.tracks.first(where: { $0.url == url })
    }

    private var titleLine: String {
        guard let url = player.player.loadedURL else {
            return String(localized: "No file loaded")
        }
        if let t = loadedTrack, !t.title.isEmpty {
            return t.title
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private var artistLine: String {
        guard player.player.loadedURL != nil else {
            return String(localized: "Open a file, drop one here, or load one from the library")
        }
        if let t = loadedTrack, !t.artist.isEmpty {
            return t.artist
        }
        return String(localized: "Unknown artist")
    }

    /// Transport-Zeile unter der Waveform: Prev · Play/Pause · Next · Sterne,
    /// rechts «•••» mit Open/Load/Unload. ⌘O liegt im Datei-Menü
    /// (`SetCraftApp`), Leertaste und Pfeiltasten hängen an den Buttons.
    private var transportBar: some View {
        HStack(spacing: 8) {
            Button {
                loadPreviousFromLibrary()
            } label: {
                Label("Previous", systemImage: "backward.end.fill")
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.Metrics.transportSide))
            .disabled(library.previousTrack(before: player.player.loadedURL) == nil)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous track in the library (←)")

            Button {
                player.togglePlay()
            } label: {
                Label("Play/Pause", systemImage: player.player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.Metrics.transportMain, kind: .prominent))
            .disabled(player.player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                loadNextFromLibrary()
            } label: {
                Label("Next", systemImage: "forward.end.fill")
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.Metrics.transportSide))
            .disabled(library.nextTrack(after: player.player.loadedURL) == nil)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next track in the library (→)")

            ratingStars
                .padding(.leading, 12)

            if let error = player.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.issueText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 12)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Open file…", systemImage: "folder.badge.plus") {
                    player.openFile()
                }
                .help("Load an audio file")
                Button("Load", systemImage: "tray.and.arrow.down.fill") {
                    loadSelectedFromLibrary()
                }
                .disabled(library.selectedTrack == nil)
                .help("Load the selected track from the library")
                Button("Unload", systemImage: "eject.fill") {
                    player.unload()
                }
                .disabled(player.player.loadedURL == nil)
                .help("Remove the track from the player")
                // Menüeinträge mit Text, auch wenn die Zeile `.iconOnly` setzt.
                .labelStyle(.titleAndIcon)
            } label: {
                Label("More actions", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ThemeButtonStyle(width: Theme.Metrics.transportSide))
            .help("More actions")
        }
        .labelStyle(.iconOnly)
        .padding(Theme.Metrics.padding)
    }

    private func loadSelectedFromLibrary() {
        guard let track = library.selectedTrack else { return }
        loadIntoPlayer(track)
    }

    private func loadNextFromLibrary() {
        guard let track = library.nextTrack(after: player.player.loadedURL) else { return }
        loadIntoPlayer(track)
    }

    private func loadPreviousFromLibrary() {
        guard let track = library.previousTrack(before: player.player.loadedURL) else { return }
        loadIntoPlayer(track)
    }

    /// Einheitlicher Lade-Pfad für alle Library-getriebenen Trigger
    /// (Selected/Prev/Next): Player füllen, Analyse anstossen, Selektion
    /// in der Library mitziehen, damit die Tabelle auf dem neuen Track steht.
    private func loadIntoPlayer(_ track: Track) {
        Self.loadIntoPlayer(track, player: player, library: library, moveSelection: true)
    }

    /// Statische Variante desselben Pfads. Der Auto-Advance-Hook lebt so lang
    /// wie der Player und darf darum keine View-Instanz festhalten — er ruft
    /// diese Funktion mit den Objekten auf, statt `self` einzufangen.
    ///
    /// `moveSelection` steuert, ob die Tabelle dem neuen Track folgt. Bei einem
    /// Klick auf Prev/Next/Load ist das gewollt; beim Auto-Advance nur dann,
    /// wenn der Nutzer die Wiedergabe ohnehin verfolgt hat — eine Mehrfach-
    /// auswahl für einen Massen-Tag-Write darf ein Trackwechsel nicht wegräumen.
    private static func loadIntoPlayer(
        _ track: Track,
        player: PlayerViewModel,
        library: LibraryViewModel,
        moveSelection: Bool
    ) {
        player.loadTrack(track)
        library.analyzeIfNeeded(track)
        if moveSelection {
            library.selectedTrackIDs = [track.id]
        }
        library.notePlay(forURL: track.url)
    }

    /// Datei kommt von aussen: Finder-Doppelklick (SetCraft als Standard-
    /// Player) oder „Öffnen mit". Zuerst abspielen — das ist es, was der
    /// Nutzer in diesem Moment erwartet — und parallel den Eltern-Ordner als
    /// Quelle sicherstellen, damit der Track auch in der Library auftaucht.
    /// Sobald der Scan ihn kennt, werden Selektion, Analyse, Play-Count und
    /// die Original-Werte der Chips nachgereicht (`player.load(url:)` allein
    /// kennt die Tags nicht).
    private func openExternalFile(_ url: URL) {
        let loading = player.load(url: url)
        Task {
            guard let track = await library.handleExternallyOpenedFile(url) else { return }
            // Der Load läuft asynchron (Prefetch) — erst danach sagt
            // `loadedURL`, ob der Track wirklich im Player steht.
            await loading.value
            library.selectedTrackIDs = [track.id]
            library.analyzeIfNeeded(track)
            library.notePlay(forURL: track.url)

            // Nur nachziehen, wenn zwischenzeitlich kein anderer Track
            // geladen wurde (Scan grosser Ordner kann dauern).
            guard player.player.loadedURL?.standardizedFileURL == track.url.standardizedFileURL
            else { return }
            player.originalBPM = track.bpm
            player.originalKey = track.key
            transport.applyMasterToLoadedTrack()
        }
    }

    private func formatTime(_ secs: TimeInterval) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension View {
    /// Anteil an der Breite in `WeightedColumns` (Standard 1).
    func layoutWeight(_ weight: Double) -> some View {
        layoutValue(key: ColumnWeight.self, value: weight)
    }
}

nonisolated private struct ColumnWeight: LayoutValueKey {
    static let defaultValue: Double = 1
}

/// Verteilt die Breite strikt nach Gewicht, unabhängig vom Inhalt — ein
/// `HStack` gibt Kindern mit breitem Inhalt mehr Platz, das Mockup verlangt
/// aber ein festes Raster. Höhe = höchstes Kind, alle Zellen gleich hoch.
private struct WeightedColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 960
        let widths = columnWidths(total: width, subviews: subviews)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columnWidths(total: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    private func columnWidths(total: CGFloat, subviews: Subviews) -> [CGFloat] {
        let weights = subviews.map { $0[ColumnWeight.self] }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in 0 } }
        return weights.map { total * $0 / sum }
    }
}

// (Preview entfernt — LibraryViewModel braucht jetzt eine LibraryRepository
//  mit DatabaseService, was im Preview-Kontext zu viel Setup wäre.)
