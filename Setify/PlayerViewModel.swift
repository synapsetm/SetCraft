import AppKit
import Foundation
import Observation
import SetifyCore
import UniformTypeIdentifiers

@Observable
final class PlayerViewModel {
    let player = AVAudioEnginePlayer()
    var lastError: String?

    /// Originaltonart und -BPM des geladenen Tracks (für Master-Logik in Phase 2).
    /// Werden bei `loadTrack(_:)` gesetzt; bei Öffnen einer reinen URL (Datei-
    /// Picker, Drop) bleiben sie `nil`.
    var originalBPM: Double?
    var originalKey: CamelotKey?

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
            originalBPM = nil
            originalKey = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Variante von `load`, die zusätzlich die in den Tags hinterlegten Original-
    /// werte mitnimmt. Wird aus der Library aufgerufen und ist die Grundlage
    /// für die Master-BPM/-Key-Logik.
    func loadTrack(_ track: Track) {
        load(url: track.url)
        // load() setzt originale auf nil — danach erst die echten Werte setzen.
        guard player.loadedURL == track.url else { return }
        originalBPM = track.bpm
        originalKey = track.key
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func unload() {
        player.unload()
        lastError = nil
        originalBPM = nil
        originalKey = nil
    }

    func cue() { player.cue() }

    func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
    }
}
