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
                cueProgress: cueProgress,
                onSeek: { fraction in
                    let duration = max(player.player.duration, 0.01)
                    player.seek(to: fraction * duration)
                }
            )
            if waveform.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Waveform wird analysiert…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
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

    private var cueProgress: Double? {
        let duration = player.player.duration
        guard duration > 0, let cue = player.player.cuePoint else { return nil }
        return max(0, min(1, cue / duration))
    }

    private var chipsBar: some View {
        HStack(spacing: 10) {
            TempoChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)
            KeyChip(transport: transport, hasLoadedTrack: transport.hasLoadedTrack)

            Spacer()

            Toggle(isOn: $transport.keyLock) {
                Label("Key-Lock", systemImage: transport.keyLock ? "lock.fill" : "lock.open")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(transport.keyLock
                ? "Key-Lock aktiv: Tempo ändert Tonhöhe nicht"
                : "Key-Lock aus: Tempo zieht die Tonhöhe mit")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.player.loadedURL?.lastPathComponent ?? "Keine Datei geladen")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        if let url = player.player.loadedURL {
            return url.deletingLastPathComponent().path
        }
        return "Datei öffnen, hineinziehen oder aus der Bibliothek laden"
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button {
                player.openFile()
            } label: {
                Label("Datei öffnen…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Audiodatei laden")

            Button {
                player.cue()
            } label: {
                Label("Cue", systemImage: "smallcircle.filled.circle")
            }
            .disabled(player.player.loadedURL == nil)

            Button {
                player.togglePlay()
            } label: {
                Label(
                    player.player.isPlaying ? "Pause" : "Play",
                    systemImage: player.player.isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .disabled(player.player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                player.unload()
            } label: {
                Label("Entladen", systemImage: "eject.fill")
            }
            .disabled(player.player.loadedURL == nil)
            .help("Track aus dem Player entfernen")

            if let cue = player.player.cuePoint {
                Text("Cue: \(formatTime(cue))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timeRow: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { player.player.position },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.player.duration, 0.01)
            )
            .disabled(player.player.loadedURL == nil)
            HStack {
                Text(formatTime(player.player.position))
                Spacer()
                Text(formatTime(player.player.duration))
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

#Preview {
    let player = PlayerViewModel()
    return ContentView(
        player: player,
        library: LibraryViewModel(),
        transport: TransportViewModel(player: player),
        waveform: WaveformViewModel()
    )
}
