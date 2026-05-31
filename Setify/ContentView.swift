import SwiftUI
import SetifyCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var player: PlayerViewModel
    @Bindable var library: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            playerPane
                .padding(16)
            Divider()
            LibraryView(library: library) { track in
                player.load(url: track.url)
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
        }
    }

    // MARK: - Player

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transport
            timeRow
            if let error = player.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
            Button("Datei öffnen…") { player.openFile() }
                .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var subtitle: String {
        if let url = player.player.loadedURL {
            return url.deletingLastPathComponent().path
        }
        return "Datei öffnen, hineinziehen oder aus der Bibliothek laden"
    }

    private var transport: some View {
        HStack(spacing: 12) {
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
    ContentView(player: PlayerViewModel(), library: LibraryViewModel())
}
