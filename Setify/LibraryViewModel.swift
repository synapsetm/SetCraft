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
    var lastAnalysisError: String?

    /// Aktuell aktive Sortierreihenfolge. Default: Titel A→Z. Mehrere
    /// Comparators sind möglich (z. B. Artist → Album → Titel).
    var sortOrder: [KeyPathComparator<Track>] = [
        KeyPathComparator(\Track.title, order: .forward)
    ]

    /// Wendet `sortOrder` auf `tracks` an. Wird vom SwiftUI-Table als
    /// Datenquelle verwendet.
    var sortedTracks: [Track] {
        tracks.sorted(using: sortOrder)
    }

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

    /// Wird nach jeder abgeschlossenen Analyse mit dem aktualisierten Track
    /// gerufen. ContentView verdrahtet das so, dass der PlayerViewModel
    /// seine originalBPM/originalKey nachzieht, wenn der Analysetrack gerade
    /// geladen ist — sonst zeigen die Player-Chips weiter "—".
    var onTrackAnalyzed: ((Track) -> Void)?

    private let repository: LibraryRepository
    private let analyzer = AnalysisCoordinator()
    private var scanTask: Task<Void, Never>?
    private var pendingSaves: [Track.ID: Task<Void, Never>] = [:]

    init(repository: LibraryRepository) {
        self.repository = repository
    }

    /// Tracks, deren Schreibvorgang abgelehnt wurde, weil die Datei im Player
    /// aktiv ist. Werden automatisch nachgeholt, sobald `setActiveTrack` auf
    /// eine andere URL wechselt.
    private var blockedByActivePlayer: Set<Track.ID> = []
    private var previousActiveURL: URL?

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

        scanTask = Task { [folder, repository] in
            for await track in repository.scan(folder: folder) {
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
            try await repository.save(track)
            unsavedTrackIDs.remove(track.id)
            blockedByActivePlayer.remove(track.id)
            lastWriteError = nil
        } catch let error as TagLibTrackStore.StoreError {
            if case .fileInUse = error {
                // Track ist gerade im Player aktiv: roten Punkt stehen
                // lassen, Schreiben wird beim Entladen automatisch nachgeholt.
                blockedByActivePlayer.insert(track.id)
            } else {
                lastWriteError = error.localizedDescription
            }
        } catch {
            lastWriteError = error.localizedDescription
        }
        pendingSaves.removeValue(forKey: track.id)
    }

    func setActiveTrack(_ url: URL?) {
        let previous = previousActiveURL
        previousActiveURL = url
        Task { [weak self, repository, previous, url] in
            await repository.setActiveTrack(url)
            await MainActor.run {
                guard let self else { return }
                if let previous, previous != url {
                    self.flushBlockedSaves(previousActiveURL: previous)
                }
            }
        }
    }

    /// Spielt zurückgestellte Schreibvorgänge ab, sobald der Player die Datei
    /// freigibt. Jedes ID-Match führt zu einem neuen `performSave` mit der
    /// aktuell im ViewModel hinterlegten Track-Version.
    private func flushBlockedSaves(previousActiveURL: URL) {
        let ids = blockedByActivePlayer.filter { id in
            tracks.first(where: { $0.id == id })?.url == previousActiveURL
        }
        for id in ids {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            blockedByActivePlayer.remove(id)
            Task { [weak self, track] in
                await self?.performSave(track)
            }
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
        let repository = repository

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
                    let gotBPM = result.bpm != nil
                    let gotKey = result.key != nil
                    if let bpm = result.bpm { updated.bpm = bpm }
                    if let key = result.key { updated.key = key }
                    self.tracks[idx] = updated
                    self.analysisState[track.id] = .done
                    if gotBPM || gotKey {
                        self.persistAfterAnalysis(updated)
                        self.onTrackAnalyzed?(updated)
                    }
                    if needsBPM && !gotBPM && needsKey && !gotKey {
                        self.lastAnalysisError = "Keine BPM und keine Tonart erkannt: \(track.url.lastPathComponent)"
                    } else if needsBPM && !gotBPM {
                        self.lastAnalysisError = "Keine BPM erkannt: \(track.url.lastPathComponent)"
                    } else if needsKey && !gotKey {
                        self.lastAnalysisError = "Keine Tonart erkannt: \(track.url.lastPathComponent)"
                    } else {
                        self.lastAnalysisError = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self?.analysisState[track.id] = .failed
                    self?.lastAnalysisError = error.localizedDescription
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
    /// damit Auto-Werte beim nächsten Programmstart vorhanden sind. Ist die
    /// Datei gerade im Player aktiv, lehnt der Store ab — `performSave`
    /// markiert sie dann für Nachschreiben beim nächsten Player-Wechsel.
    private func persistAfterAnalysis(_ track: Track) {
        unsavedTrackIDs.insert(track.id)
        pendingSaves[track.id]?.cancel()
        pendingSaves[track.id] = nil
        Task { [weak self, track] in
            await self?.performSave(track)
        }
    }
}
