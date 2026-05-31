import AppKit
import Foundation
import Observation
import SetifyCore

@Observable
final class LibraryViewModel {
    var tracks: [Track] = []
    var folderURL: URL?
    var isScanning = false
    var selectedTrackID: Track.ID?
    var lastWriteError: String?

    private let store = TagLibTrackStore()
    private var scanTask: Task<Void, Never>?
    private var pendingSaves: [Track.ID: Task<Void, Never>] = [:]

    /// Debounce-Fenster für Inline-Edits: spätestens danach landet das letzte
    /// Setzen auf der Platte. Kürzere Eingaben kollabieren in einen Schreibvorgang.
    private let saveDebounce: Duration = .milliseconds(600)

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Musikordner wählen"
        if panel.runModal() == .OK, let url = panel.url {
            scan(folder: url)
        }
    }

    func scan(folder: URL) {
        scanTask?.cancel()
        folderURL = folder
        tracks = []
        isScanning = true

        scanTask = Task { [folder] in
            for await track in FolderScanner.scan(folder: folder) {
                if Task.isCancelled { break }
                tracks.append(track)
            }
            isScanning = false
        }
    }

    var selectedTrack: Track? {
        guard let id = selectedTrackID else { return nil }
        return tracks.first(where: { $0.id == id })
    }

    // MARK: - Persistence

    /// Vom UI nach jeder Mutation aufrufen. Mehrere schnelle Aufrufe für
    /// denselben Track werden zu einem einzigen Schreibvorgang gebündelt.
    func scheduleSave(_ track: Track) {
        pendingSaves[track.id]?.cancel()
        let debounce = saveDebounce
        let store = store
        pendingSaves[track.id] = Task { [weak self, track] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            do {
                try await store.save(track)
                self?.lastWriteError = nil
            } catch {
                self?.lastWriteError = error.localizedDescription
            }
        }
    }

    func setActiveTrack(_ url: URL?) {
        Task { [store] in
            await store.setActiveTrack(url)
        }
    }
}
