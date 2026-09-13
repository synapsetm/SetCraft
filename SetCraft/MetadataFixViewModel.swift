import Foundation
import Observation
import SetCraftCore

/// Steuert einen Lauf der Metadaten-Kette und hält die Vorschläge, bis der
/// Nutzer entschieden hat. Schreibt selbst nichts — das Übernehmen geht durch
/// `LibraryViewModel.applyMetadata`, damit Tag-Writes weiterhin über genau
/// einen Pfad laufen (Scope-Token, Serialisierung, Active-Track-Guard).
@MainActor
@Observable
final class MetadataFixViewModel {

    /// Welche Tracks ein Lauf betrachtet.
    enum Scope: String, CaseIterable, Identifiable {
        case selection
        case missing
        case all

        var id: String { rawValue }
    }

    var proposals: [MetadataProposal] = []
    var isRunning = false
    var processed = 0
    var total = 0
    var lastError: String?
    /// Grobe Schätzung in Sekunden, bevor der Lauf startet.
    var estimatedSeconds: Double = 0
    /// Wurde schon einmal gelaufen? Unterscheidet „noch nichts gemacht" von
    /// „nichts gefunden".
    var didRun = false

    private var runTask: Task<Void, Never>?
    private let library: LibraryViewModel

    init(library: LibraryViewModel) {
        self.library = library
    }

    // MARK: - Abgeleitetes

    var acceptedFieldCount: Int {
        proposals.reduce(0) { sum, proposal in
            sum + proposal.fields.filter(\.isAccepted).count
        }
    }

    var acceptedTrackCount: Int {
        proposals.filter { $0.fields.contains(where: \.isAccepted) }.count
    }

    func tracks(for scope: Scope) -> [Track] {
        switch scope {
        case .selection: return library.selectedTracks
        case .missing:   return library.tracksMissingTags
        case .all:       return library.tracks
        }
    }

    // MARK: - Lauf

    func start(scope: Scope, settings: MetadataFixRunner.Settings) {
        let tracks = tracks(for: scope)
        guard !tracks.isEmpty else { return }

        runTask?.cancel()
        proposals = []
        processed = 0
        total = tracks.count
        lastError = nil
        isRunning = true
        didRun = true

        let runner = MetadataFixRunner(settings: settings, cache: library.catalogCache)
        estimatedSeconds = runner.estimatedSeconds(trackCount: tracks.count)

        // Der Kontext lernt aus **allen** Tracks der Quelle, nicht nur aus den
        // betrachteten: die getaggten Geschwister sind das Lehrmaterial für das
        // Namensschema, und genau die stehen nicht in der Auswahl.
        let context = runner.context(
            folder: library.folderURL,
            folderTracks: library.tracks,
            library: library.tracks
        )

        runTask = Task { [weak self] in
            for await proposal in runner.proposals(for: tracks, context: context) {
                guard let self, !Task.isCancelled else { break }
                self.processed += 1
                guard proposal.hasChanges else { continue }
                self.proposals.append(proposal)
            }
            self?.isRunning = false
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    // MARK: - Auswahl

    /// Hakt alle Vorschläge an bzw. ab. `onlyMissingValues` lässt Felder aus,
    /// die bereits einen Wert haben — Überschreiben bleibt Handarbeit.
    func setAllAccepted(_ accepted: Bool, onlyMissingValues: Bool) {
        for proposalIndex in proposals.indices {
            for fieldIndex in proposals[proposalIndex].fields.indices {
                let field = proposals[proposalIndex].fields[fieldIndex]
                if accepted && onlyMissingValues && field.isOverwrite { continue }
                proposals[proposalIndex].fields[fieldIndex].isAccepted = accepted
            }
        }
    }

    /// Hakt nur an, was die Kette als belastbar einstuft.
    func acceptHighConfidenceOnly() {
        for proposalIndex in proposals.indices {
            for fieldIndex in proposals[proposalIndex].fields.indices {
                let field = proposals[proposalIndex].fields[fieldIndex]
                let trustworthy = SuggestionConfidence.level(field.confidence) == .high
                proposals[proposalIndex].fields[fieldIndex].isAccepted = trustworthy && !field.isOverwrite
            }
        }
    }

    // MARK: - Übernehmen

    /// Schreibt die angehakten Felder über den Library-Pfad zurück und entfernt
    /// die erledigten Vorschläge aus der Liste. Liefert die Zahl der geänderten
    /// Tracks.
    @discardableResult
    func applyAccepted() -> Int {
        var changed = 0
        var remaining: [MetadataProposal] = []

        for proposal in proposals {
            guard proposal.fields.contains(where: \.isAccepted) else {
                remaining.append(proposal)
                continue
            }
            if library.applyMetadata(proposal) {
                changed += 1
            } else {
                remaining.append(proposal)
            }
        }
        proposals = remaining
        return changed
    }
}
