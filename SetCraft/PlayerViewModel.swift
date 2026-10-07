import AppKit
import Foundation
import Observation
import SetCraftCore
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
        panel.title = String(localized: "Open audio file")
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    /// Laufender Load. Ein neuer Load bricht ihn ab — beim schnellen
    /// Durchklicken soll nur der zuletzt gewählte Track ankommen.
    private var loadTask: Task<Void, Never>?

    /// URL des Tracks, der gerade geholt wird — zwischen Klick und erstem
    /// Ton. Bei einer NAS-Quelle steckt darin die Kopie in den
    /// `PlaybackCache`; Waveform-Overlay und Library-Zeile zeigen solange
    /// einen Ladezustand. Gleiches Modell wie `PlayerStore` auf iOS.
    var loadingURL: URL?

    /// Anteil der übertragenen Bytes des gerade geladenen Tracks, 0…1.
    /// `nil`, solange nichts bekannt ist — die Kopie hat noch nicht
    /// begonnen, oder die Quelle ist lokal und wird gar nicht kopiert.
    var loadProgress: Double?

    /// Holt die Datei zuerst auf der Materialisierungs-Queue
    /// (`AVAudioEnginePlayer.prefetch`), erst danach öffnet `player.load` sie
    /// auf dem MainActor. Bis 2026-10-07 öffnete der Mac die Quelle direkt
    /// hier — bei einer SMB-Quelle synchroner Datei-IO auf dem MainActor,
    /// und ohne `PlaybackCache` hing die Wiedergabe am Netz. Liegt im Cache
    /// eine Kopie (Netz-Volume), spielt der Load aus ihr; lokale Dateien
    /// kostet der Prefetch nur einen Open.
    ///
    /// Der zurückgegebene Task endet, wenn der Load durch ist — wer danach
    /// `player.loadedURL` vergleichen will, wartet darauf.
    @discardableResult
    func load(url: URL) -> Task<Void, Never> {
        load(url: url, then: nil)
    }

    @discardableResult
    private func load(url: URL, then onLoaded: (() -> Void)?) -> Task<Void, Never> {
        loadTask?.cancel()
        loadingURL = url
        loadProgress = nil
        let task = Task { [weak self] in
            do {
                try await AVAudioEnginePlayer.prefetch(url: url) { [weak self] fraction in
                    Task { @MainActor in
                        // Ein spät eintreffender Fortschritt eines abgelösten
                        // Loads darf die Anzeige nicht mehr anfassen.
                        guard let self, self.loadingURL == url else { return }
                        self.loadProgress = fraction
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finishLoading(url)
                self.lastError = Self.message(for: error)
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.finishLoading(url)
            self.load(url: url, allowRetry: true)
            if self.player.loadedURL == url {
                onLoaded?()
            }
        }
        loadTask = task
        return task
    }

    /// Räumt den Ladezustand weg — aber nur, wenn er noch diesem Load gehört.
    private func finishLoading(_ url: URL) {
        guard loadingURL == url else { return }
        loadingURL = nil
        loadProgress = nil
    }

    /// `allowRetry` deckt den einen Fall ab, in dem ein zweiter Versuch etwas
    /// bringt: die lokale Wiedergabe-Kopie (auf dem Mac nur bei gemounteten
    /// Netz-Volumes) liess sich nicht öffnen. Sie ist dann bereits verworfen,
    /// der zweite Anlauf geht an die Quelle. Alles andere scheitert auch beim
    /// zweiten Mal und wird gemeldet.
    private func load(url: URL, allowRetry: Bool) {
        do {
            try player.load(url: url)
            lastError = nil
            originalBPM = nil
            originalKey = nil
            // Direkt nach dem Laden mitlaufen — DJ-typisch erwartet man hier
            // keinen separaten Play-Klick.
            player.play()
        } catch AudioEngineError.cachedCopyUnusable where allowRetry {
            load(url: url, allowRetry: false)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Fehlertext für die rote Zeile unter dem Player. Die Fälle mit eigenem
    /// Satz sind die, bei denen der CoreAudio-Code dem Nutzer nichts sagt.
    private static func message(for error: Error) -> String {
        switch error {
        case AudioEngineError.fileMissing:
            String(localized: "This track no longer exists at its location — it was moved or deleted.")
        case AudioEngineError.sourceOffline:
            String(localized: "The source is not reachable and this track is not stored locally.")
        default:
            error.localizedDescription
        }
    }

    /// Variante von `load`, die zusätzlich die in den Tags hinterlegten Original-
    /// werte mitnimmt. Wird aus der Library aufgerufen und ist die Grundlage
    /// für die Master-BPM/-Key-Logik.
    func loadTrack(_ track: Track) {
        // load() setzt originale auf nil — danach erst die echten Werte setzen.
        load(url: track.url) { [weak self] in
            self?.originalBPM = track.bpm
            self?.originalKey = track.key
        }
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

    func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
    }
}
