import AppKit
import Foundation
import Observation
import SetifyCore
import UniformTypeIdentifiers

@Observable
final class PlayerViewModel {
    let player = AVAudioEnginePlayer()
    var lastError: String?

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Audiodatei öffnen"
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        do {
            try player.load(url: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func cue() { player.cue() }

    func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
    }
}
