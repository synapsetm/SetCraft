import SwiftUI
import SetifyCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var viewModel: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            transport
            timeRow
            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 320)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            viewModel.load(url: url)
            return true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.player.loadedURL?.lastPathComponent ?? "Keine Datei geladen")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Datei öffnen…") { viewModel.openFile() }
                .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var subtitle: String {
        if let url = viewModel.player.loadedURL {
            return url.deletingLastPathComponent().path
        }
        return "Datei öffnen oder hier hineinziehen"
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.cue()
            } label: {
                Label("Cue", systemImage: "smallcircle.filled.circle")
            }
            .disabled(viewModel.player.loadedURL == nil)

            Button {
                viewModel.togglePlay()
            } label: {
                Label(
                    viewModel.player.isPlaying ? "Pause" : "Play",
                    systemImage: viewModel.player.isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .disabled(viewModel.player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [])

            if let cue = viewModel.player.cuePoint {
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
                    get: { viewModel.player.position },
                    set: { viewModel.seek(to: $0) }
                ),
                in: 0...max(viewModel.player.duration, 0.01)
            )
            .disabled(viewModel.player.loadedURL == nil)
            HStack {
                Text(formatTime(viewModel.player.position))
                Spacer()
                Text(formatTime(viewModel.player.duration))
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
    ContentView(viewModel: PlayerViewModel())
}
