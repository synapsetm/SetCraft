import AppKit
import Foundation
import Observation
import SetifyCore

@Observable
final class LibraryViewModel {
    enum AnalysisState: Sendable {
        case idle
        case scheduled
        case done
        case failed
    }

    var tracks: [Track] = []
    var folderURL: URL?
    var isScanning = false
    var selectedTrackID: Track.ID?
    var lastWriteError: String?

    /// IDs der Tracks mit Änderungen, die noch nicht auf der Platte sind.
    /// Erst nach erfolgreichem `save` wird die ID hier wieder entfernt.
    var unsavedTrackIDs: Set<Track.ID> = []

    var hasUnsavedChanges: Bool { !unsavedTrackIDs.isEmpty }

    /// Welcher Track aktuell analysiert wird (oder bereits analysiert wurde).
    var analysisState: [Track.ID: AnalysisState] = [:]

    /// Wahl des erwarteten BPM-Bereichs für die Oktav-Korrektur.
    var bpmPreset: BPMRangePreset = .universal

    var pendingAnalysisCount: Int {
        analysisState.values.lazy.filter { $0 == .scheduled }.count
    }

    private let store = TagLibTrackStore()
    private let analyzer = AnalysisCoordinator()
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
        unsavedTrackIDs.insert(track.id)
        pendingSaves[track.id]?.cancel()
        let debounce = saveDebounce
        pendingSaves[track.id] = Task { [weak self, track] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self?.performSave(track)
        }
    }

    /// Manueller Speicher-Befehl (z. B. ⌘S oder Toolbar-Knopf): bricht das
    /// Debouncing ab und schreibt alle aktuell dirty Tracks sofort.
    func saveAllNow() {
        for (_, task) in pendingSaves { task.cancel() }
        pendingSaves.removeAll()
        let dirty = unsavedTrackIDs
        for id in dirty {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            Task { [weak self, track] in
                await self?.performSave(track)
            }
        }
    }

    private func performSave(_ track: Track) async {
        do {
            try await store.save(track)
            unsavedTrackIDs.remove(track.id)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
        }
        pendingSaves.removeValue(forKey: track.id)
    }

    func setActiveTrack(_ url: URL?) {
        Task { [store] in
            await store.setActiveTrack(url)
        }
    }

    // MARK: - Analyse

    /// Startet eine Analyse für `track`, wenn BPM oder Key fehlen. Ein zweiter
    /// Aufruf während laufender Analyse wird ignoriert.
    func analyzeIfNeeded(_ track: Track) {
        let needsBPM = track.bpm == nil
        let needsKey = track.key == nil
        guard needsBPM || needsKey else { return }
        if analysisState[track.id] == .scheduled { return }

        analysisState[track.id] = .scheduled
        let preset = bpmPreset
        let analyzer = analyzer
        let store = store

        Task { [weak self, track, needsBPM, needsKey, preset] in
            do {
                let result = try await analyzer.analyze(
                    url: track.url,
                    needsBPM: needsBPM,
                    needsKey: needsKey,
                    bpmRange: preset
                )
                await MainActor.run {
                    guard let self else { return }
                    guard let idx = self.tracks.firstIndex(where: { $0.id == track.id }) else {
                        self.analysisState[track.id] = .done
                        return
                    }
                    var updated = self.tracks[idx]
                    if let bpm = result.bpm { updated.bpm = bpm }
                    if let key = result.key { updated.key = key }
                    self.tracks[idx] = updated
                    self.analysisState[track.id] = .done
                    self.persistAfterAnalysis(updated, store: store)
                }
            } catch {
                await MainActor.run {
                    self?.analysisState[track.id] = .failed
                    self?.lastWriteError = error.localizedDescription
                }
            }
        }
    }

    /// Startet die Analyse für alle Tracks mit fehlendem BPM oder Key.
    func analyzeAllMissing() {
        for track in tracks where track.bpm == nil || track.key == nil {
            analyzeIfNeeded(track)
        }
    }

    /// Analysisergebnisse landen direkt auf der Platte (ohne 600-ms-Debounce),
    /// damit Auto-Werte beim nächsten Programmstart vorhanden sind. Ein
    /// laufender User-Save zum selben Track wird abgebrochen, weil der
    /// Analysetrack dieselbe Quelle der Wahrheit ist.
    private func persistAfterAnalysis(_ track: Track, store: TagLibTrackStore) {
        pendingSaves[track.id]?.cancel()
        pendingSaves[track.id] = nil
        Task { [weak self, track, store] in
            do {
                try await store.save(track)
                await MainActor.run {
                    self?.unsavedTrackIDs.remove(track.id)
                    self?.lastWriteError = nil
                }
            } catch {
                await MainActor.run {
                    self?.lastWriteError = error.localizedDescription
                }
            }
        }
    }
}
