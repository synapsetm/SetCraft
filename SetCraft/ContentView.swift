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
            playerPane
                .padding(16)
            Divider()
            LibraryView(library: library) { track in
                player.loadTrack(track)
                library.analyzeIfNeeded(track)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // Track muss im Player landen UND in der Library erscheinen.
            // Falls der Eltern-Ordner noch nicht als Quelle bekannt ist,
            // fragt die Library den Nutzer einmalig (sandbox-bedingt).
            library.handleDroppedFile(url)
            player.load(url: url)
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
            library.restoreSavedFolders()
        }
    }

    // MARK: - Player

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transportControls
            timeRow
            waveformRow
            chipsBar
            if let error = player.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

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
            if waveform.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing waveform…")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .padding(8)
            } else if let error = waveform.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(8)
            }
        }
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
        return Double(w.bins.count) * w.secondsPerBin
    }

    private var chipsBar: some View {
        HStack(spacing: 12) {
            TempoChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
            KeyChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
            ratingChip
            Spacer()
        }
    }

    /// Sterne-Rating für den aktuell geladenen Track. Capsule-Rahmen wie der
    /// TempoChip signalisiert „antippbar"; gedimmt + Tap deaktiviert, sobald
    /// der Track nicht in der Library steht (ohne `Track`-Eintrag fehlt das
    /// Persistenz-Ziel).
    @ViewBuilder
    private var ratingChip: some View {
        let editable = loadedTrack != nil
        StarRatingView(rating: loadedTrack?.rating ?? .none) { newRating in
            guard let url = player.player.loadedURL else { return }
            library.setRating(forURL: url, newRating)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .disabled(!editable)
        .opacity(editable ? 1.0 : 0.45)
        .help(editable ? "Rating" : "Track is not in the library — rating can't be saved")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkView(url: player.player.loadedURL, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(titleLine)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(artistLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
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

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button {
                player.openFile()
            } label: {
                Label("Open file…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Load an audio file")

            Button {
                loadSelectedFromLibrary()
            } label: {
                Label("Load", systemImage: "tray.and.arrow.down.fill")
            }
            .disabled(library.selectedTrack == nil)
            .help("Load the selected track from the library")

            Button {
                loadPreviousFromLibrary()
            } label: {
                Label("Previous", systemImage: "backward.fill")
            }
            .disabled(library.previousTrack(before: player.player.loadedURL) == nil)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous track in the library (←)")

            Button {
                player.togglePlay()
            } label: {
                Label("Play/Pause", systemImage: "playpause.fill")
            }
            .disabled(player.player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                loadNextFromLibrary()
            } label: {
                Label("Next", systemImage: "forward.fill")
            }
            .disabled(library.nextTrack(after: player.player.loadedURL) == nil)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next track in the library (→)")

            Button {
                player.unload()
            } label: {
                Label("Unload", systemImage: "eject.fill")
            }
            .disabled(player.player.loadedURL == nil)
            .help("Remove the track from the player")
        }
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
        player.loadTrack(track)
        library.analyzeIfNeeded(track)
        library.selectedTrackID = track.id
    }

    /// Nur noch die Zeitanzeige — gesucht wird ab Phase 4 ausschliesslich
    /// über die Waveform. Format: gespielte Zeit / -verbleibend.
    ///
    /// Per `TimelineView(.periodic)` 1 × pro Sekunde aktualisiert; gelesen
    /// wird `livePosition` (frisch aus `lastRenderTime`) statt der
    /// @Observable-`position`, sodass die Zeile auch dann tickt, wenn das
    /// Observation-Update zwischen TimelineView-Ticks aus irgendeinem
    /// Grund (z. B. Tab-Wechsel) ausbleibt.
    private var timeRow: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let pos = player.player.livePosition
            let dur = player.player.duration
            HStack {
                Text("\(formatTime(pos)) / -\(formatTime(max(0, dur - pos)))")
                Spacer()
                Text(formatTime(dur))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func formatTime(_ secs: TimeInterval) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// (Preview entfernt — LibraryViewModel braucht jetzt eine LibraryRepository
//  mit DatabaseService, was im Preview-Kontext zu viel Setup wäre.)
