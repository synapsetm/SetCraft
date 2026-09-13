//
//  MetadataFixStore.swift
//  SetCraft iOS
//

import Foundation
import Observation
import SetCraftCore

/// iOS-Pendant zum Mac-`MetadataFixViewModel`: steuert einen Lauf der
/// Metadaten-Kette und hält die Vorschläge, bis der Nutzer entschieden hat.
/// Schreibt nichts selbst — das Übernehmen geht durch
/// `LibraryStore.applyMetadata`, damit Tag-Writes weiterhin über genau einen
/// Pfad laufen (Scope-Token, Serialisierung, Active-Track-Guard).
@Observable
@MainActor
final class MetadataFixStore {

    enum Scope: String, CaseIterable, Identifiable {
        case missing
        case all

        var id: String { rawValue }
    }

    var proposals: [MetadataProposal] = []
    var isRunning = false
    var processed = 0
    var total = 0
    var lastError: String?
    var estimatedSeconds: Double = 0
    var didRun = false

    private var runTask: Task<Void, Never>?
    private let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    // MARK: - Abgeleitetes

    var acceptedFieldCount: Int {
        proposals.reduce(0) { $0 + $1.fields.filter(\.isAccepted).count }
    }

    var acceptedTrackCount: Int {
        proposals.filter { $0.fields.contains(where: \.isAccepted) }.count
    }

    func tracks(for scope: Scope) -> [Track] {
        switch scope {
        case .missing: return library.tracksMissingTags
        case .all:     return library.tracks
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

        // Gelernt wird aus **allen** Tracks der Quelle: die getaggten
        // Geschwister sind das Lehrmaterial, und genau die sind nicht dabei,
        // wenn nur die unvollständigen betrachtet werden.
        let context = runner.context(
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

    func setAllAccepted(_ accepted: Bool, onlyMissingValues: Bool) {
        for proposalIndex in proposals.indices {
            for fieldIndex in proposals[proposalIndex].fields.indices {
                let field = proposals[proposalIndex].fields[fieldIndex]
                if accepted && onlyMissingValues && field.isOverwrite { continue }
                proposals[proposalIndex].fields[fieldIndex].isAccepted = accepted
            }
        }
    }

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

    @discardableResult
    func applyAccepted() async -> Int {
        var changed = 0
        var remaining: [MetadataProposal] = []

        for proposal in proposals {
            guard proposal.fields.contains(where: \.isAccepted) else {
                remaining.append(proposal)
                continue
            }
            if await library.applyMetadata(proposal) {
                changed += 1
            } else {
                remaining.append(proposal)
            }
        }
        proposals = remaining
        return changed
    }
}
