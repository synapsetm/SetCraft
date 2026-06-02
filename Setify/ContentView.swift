import SwiftUI
import SetifyCore
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
            WaveformView(
                data: waveform.data,
                progress: waveformProgress,
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

    private var waveformProgress: Double {
        let duration = player.player.duration
        guard duration > 0 else { return 0 }
        return max(0, min(1, player.player.position / duration))
    }

    private var chipsBar: some View {
        HStack(spacing: 12) {
            TempoChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
            KeyChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
            Spacer()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
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
                player.togglePlay()
            } label: {
                Label("Play/Pause", systemImage: "playpause.fill")
            }
            .disabled(player.player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [])

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
        player.loadTrack(track)
        library.analyzeIfNeeded(track)
    }

    /// Nur noch die Zeitanzeige — gesucht wird ab Phase 4 ausschliesslich
    /// über die Waveform. Format: gespielte Zeit / -verbleibend.
    private var timeRow: some View {
        HStack {
            Text("\(formatTime(player.player.position)) / -\(formatTime(remainingTime))")
            Spacer()
            Text(formatTime(player.player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var remainingTime: TimeInterval {
        max(0, player.player.duration - player.player.position)
    }

    private func formatTime(_ secs: TimeInterval) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// (Preview entfernt — LibraryViewModel braucht jetzt eine LibraryRepository
//  mit DatabaseService, was im Preview-Kontext zu viel Setup wäre.)
