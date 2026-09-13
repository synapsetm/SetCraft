import Foundation
import OSLog

/// Was für einen ganzen Lauf gilt: das im Ordner gelernte Namensschema, die
/// Ordner-Infos und der Index für den Zwillings-Abgleich. Einmal bauen, für
/// alle Tracks des Ordners benutzen.
public struct MetadataContext: Sendable {
    public var pattern: NamingPattern?
    public var folder: FolderContext
    public var duplicates: DuplicateMatcher

    public init(pattern: NamingPattern?, folder: FolderContext, duplicates: DuplicateMatcher) {
        self.pattern = pattern
        self.folder = folder
        self.duplicates = duplicates
    }

    /// `folderTracks` sind die Dateien des betrachteten Ordners (Lehrmaterial
    /// für das Schema), `library` alle bekannten Tracks (Kandidaten für den
    /// Zwillings-Abgleich — der darf ordnerübergreifend suchen).
    public static func build(folder: URL?, folderTracks: [Track], library: [Track]) -> MetadataContext {
        MetadataContext(
            pattern: PatternLearner.learn(from: folderTracks),
            folder: folder.map { FolderContext.merging(folder: $0, siblings: folderTracks) } ?? FolderContext(),
            duplicates: DuplicateMatcher(tracks: library)
        )
    }
}

/// Die Vorschlagskette: Dateiname → Ordner-Schema → Zwilling in der Bibliothek
/// → Katalog-Gegenprüfung.
///
/// Jede Stufe darf die vorige überstimmen, wenn sie verlässlicher ist; die
/// Confidence wandert mit. Geschrieben wird hier **nichts** — das Ergebnis ist
/// ein `MetadataProposal`, über das der Nutzer im Review-Sheet entscheidet.
public struct MetadataResolver: Sendable {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "MetadataResolver")

    public struct Options: Sendable {
        /// Welche Felder überhaupt vorgeschlagen werden dürfen.
        public var fields: Set<MetadataField>
        public var policy: CatalogCheckPolicy
        /// Unter dieser Confidence gilt ein Offline-Vorschlag als wackelig und
        /// löst bei `.whenUncertain` eine Katalog-Abfrage aus.
        public var uncertaintyThreshold: Double
        /// Ab dieser Punktzahl akzeptieren wir einen Katalog-Treffer überhaupt.
        public var minimumCatalogScore: Double

        public init(
            fields: Set<MetadataField> = MetadataField.all,
            policy: CatalogCheckPolicy = .whenUncertain,
            uncertaintyThreshold: Double = 0.8,
            minimumCatalogScore: Double = 0.6
        ) {
            self.fields = fields
            self.policy = policy
            self.uncertaintyThreshold = uncertaintyThreshold
            self.minimumCatalogScore = minimumCatalogScore
        }
    }

    private let catalog: CatalogLookup?
    private let options: Options

    public init(catalog: CatalogLookup? = nil, options: Options = Options()) {
        self.catalog = catalog
        self.options = options
    }

    // MARK: - Einzelner Track

    public func proposal(for track: Track, context: MetadataContext) async -> MetadataProposal {
        var notes: [ProposalNote] = []
        var candidates: [MetadataField: Candidate] = [:]

        // ── Stufe 1+2: Dateiname, ausgerichtet am Ordner-Schema ────────────
        var parsed = FilenameParser.parse(url: track.url)
        var nameConfidence = 0.55

        if let pattern = context.pattern, pattern.isTrustworthy, parsed.hasSeparator {
            let aligned = PatternLearner.apply(pattern, to: parsed)
            notes.append(aligned.artist == parsed.artist ? .folderPatternApplied : .folderPatternSwapped)
            parsed = aligned
            nameConfidence = pattern.confidence
        } else if !parsed.orderIsAmbiguous && parsed.hasSeparator {
            // Die Mix-Klammer hat die Reihenfolge verraten.
            nameConfidence = 0.75
        }

        if parsed.hasSeparator {
            if parsed.orderIsAmbiguous { notes.append(.orderAmbiguous) }
            if parsed.separatorWasWeak {
                notes.append(.weakSeparator)
                nameConfidence -= 0.15
            }
        } else {
            notes.append(.noSeparator)
        }

        let nameSource: SuggestionSource = context.pattern?.isTrustworthy == true ? .folderPattern : .filename
        put(&candidates, .title, parsed.title, nameSource, nameConfidence)
        put(&candidates, .artist, parsed.artist, nameSource, nameConfidence)
        if let year = parsed.year {
            put(&candidates, .year, String(year), nameSource, nameConfidence)
        }

        // ── Ordner: Album, Label, Jahr ─────────────────────────────────────
        put(&candidates, .album, context.folder.album, .folderName, 0.65)
        put(&candidates, .label, context.folder.label, .folderName, 0.65)
        if let year = context.folder.year {
            put(&candidates, .year, String(year), .folderName, 0.6)
        }
        // Ordner-Artist nur, wenn der Dateiname keinen hergibt — bei
        // Compilations ist er falsch.
        if parsed.artist.isEmpty {
            put(&candidates, .artist, context.folder.albumArtist, .folderName, 0.5)
        }

        // ── Stufe 3: getaggter Zwilling in der Bibliothek ───────────────────
        if let match = context.duplicates.match(for: track) {
            notes.append(match.reason == .identicalFile ? .identicalFileFound : .libraryDuplicate)
            let twin = match.track
            put(&candidates, .artist, twin.artist, .libraryDuplicate, match.confidence)
            put(&candidates, .title, twin.title, .libraryDuplicate, match.confidence)
            put(&candidates, .album, twin.album, .libraryDuplicate, match.confidence)
            put(&candidates, .label, twin.label, .libraryDuplicate, match.confidence)
            if let year = twin.year {
                put(&candidates, .year, String(year), .libraryDuplicate, match.confidence)
            }
        }

        // ── Stufe 4: Katalog als Gegenprüfung ──────────────────────────────
        var reference: String?
        if let catalog, options.policy != .off {
            if shouldCheckCatalog(candidates: candidates, parsed: parsed, track: track) {
                let query = CatalogQuery(
                    artist: candidates[.artist]?.value ?? parsed.artist,
                    title: bareTitle(candidates[.title]?.value ?? parsed.title),
                    mixVersion: parsed.mixVersion,
                    catalogNumber: parsed.catalogNumber,
                    year: candidates[.year].flatMap { Int($0.value) },
                    durationSeconds: track.durationSeconds
                )
                if query.isUsable {
                    reference = await applyCatalog(catalog, query: query, candidates: &candidates, notes: &notes)
                }
            } else {
                notes.append(.catalogNotChecked)
            }
        }

        // ── Vorschläge bauen ───────────────────────────────────────────────
        var fields: [FieldSuggestion] = []
        for field in MetadataField.allCases {
            guard options.fields.contains(field),
                  let candidate = candidates[field],
                  !candidate.value.isEmpty else { continue }

            let current = currentValue(of: field, in: track)
            let suggestion = FieldSuggestion(
                field: field,
                value: candidate.value,
                currentValue: current,
                source: candidate.source,
                confidence: min(1.0, max(0.0, candidate.confidence)),
                isAccepted: current.isEmpty && candidate.confidence >= SuggestionConfidence.autoAcceptThreshold
            )
            guard !suggestion.isRedundant else { continue }
            fields.append(suggestion)
        }

        return MetadataProposal(
            url: track.url,
            track: track,
            parsed: parsed,
            fields: fields,
            notes: notes,
            catalogReference: reference
        )
    }

    // MARK: - Stapel

    /// Streamt Vorschläge, damit das Review-Sheet Zeilen einzeln anzeigen kann —
    /// bei Katalog-Abfragen dauert ein Lauf über hunderte Dateien Minuten.
    /// Tracks werden der Reihe nach abgearbeitet; die Serialisierung ist
    /// Absicht, weil am anderen Ende ein Rate-Limit hängt.
    public func proposals(for tracks: [Track], context: MetadataContext) -> AsyncStream<MetadataProposal> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                for track in tracks {
                    if Task.isCancelled { break }
                    continuation.yield(await proposal(for: track, context: context))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Katalog

    /// Entscheidet, ob der Katalog gefragt wird.
    ///
    /// „Unsicher" heisst: Kernfelder fehlen, die Reihenfolge ist unklar, der
    /// Trenner war schwach, oder die Confidence liegt unter der Schwelle.
    /// „Unvollständig" heisst: ein **angefordertes** Feld ist nach den
    /// Offline-Stufen noch leer — bei Album/Label/Jahr ist der Katalog dann
    /// die einzige verbleibende Quelle.
    func shouldCheckCatalog(
        candidates: [MetadataField: Candidate],
        parsed: ParsedFilename,
        track: Track
    ) -> Bool {
        if options.policy == .always { return true }

        for field in options.fields {
            let candidate = candidates[field]?.value ?? ""
            let current = currentValue(of: field, in: track)
            if candidate.isEmpty && current.isEmpty { return true }
        }
        if parsed.orderIsAmbiguous && parsed.hasSeparator { return true }
        if parsed.separatorWasWeak { return true }
        if !parsed.hasSeparator { return true }

        let coreConfidence = MetadataField.core
            .compactMap { candidates[$0]?.confidence }
            .min() ?? 0
        return coreConfidence < options.uncertaintyThreshold
    }

    /// Fragt den Katalog und verrechnet den besten Treffer mit den bisherigen
    /// Kandidaten. Liefert die Provenienz des verwendeten Treffers.
    private func applyCatalog(
        _ catalog: CatalogLookup,
        query: CatalogQuery,
        candidates: inout [MetadataField: Candidate],
        notes: inout [ProposalNote]
    ) async -> String? {
        let matches: [CatalogMatch]
        do {
            matches = try await catalog.search(query)
        } catch {
            Self.log.notice("Catalog lookup failed for \(query.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            notes.append(.catalogUnavailable)
            return nil
        }

        guard let best = matches.first, best.score >= options.minimumCatalogScore else {
            notes.append(.catalogNoMatch)
            return nil
        }
        // Zweiter Treffer dicht dahinter → der Nutzer soll zweimal hinschauen.
        if matches.count > 1, matches[1].score >= best.score - 0.05 {
            notes.append(.catalogAmbiguous)
        }

        var confirmed = false
        var corrected = false
        // Gut genug bestätigt ist besser als alles Offline-Geratene; ein
        // Widerspruch wiegt weniger, weil Discogs auf Release-Ebene arbeitet
        // und der Treffer eine andere Fassung sein kann.
        let confirmConfidence = min(0.97, 0.75 + best.score * 0.2)
        let correctConfidence = min(0.9, 0.5 + best.score * 0.4)

        func merge(_ field: MetadataField, _ value: String) {
            guard !value.isEmpty else { return }
            if let existing = candidates[field], !existing.value.isEmpty {
                if TextSimilarity.similarity(existing.value, value) >= 0.85 {
                    confirmed = true
                    candidates[field] = Candidate(
                        value: existing.value,
                        source: existing.source,
                        confidence: max(existing.confidence, confirmConfidence)
                    )
                } else {
                    corrected = true
                    candidates[field] = Candidate(value: value, source: .catalog, confidence: correctConfidence)
                }
            } else {
                candidates[field] = Candidate(value: value, source: .catalog, confidence: correctConfidence)
            }
        }

        merge(.artist, best.artist)
        merge(.title, best.title)
        merge(.album, best.album)
        merge(.label, best.label)
        if let year = best.year { merge(.year, String(year)) }

        if corrected {
            notes.append(.catalogCorrected)
        } else if confirmed {
            notes.append(.catalogConfirmed)
        }
        return best.reference.isEmpty ? nil : best.reference
    }

    // MARK: - Helpers

    /// Ein Kandidat, solange noch Stufen folgen können.
    struct Candidate: Sendable {
        var value: String
        var source: SuggestionSource
        var confidence: Double
    }

    /// Trägt einen Kandidaten ein, wenn er besser ist als der bisherige.
    private func put(
        _ candidates: inout [MetadataField: Candidate],
        _ field: MetadataField,
        _ value: String,
        _ source: SuggestionSource,
        _ confidence: Double
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let existing = candidates[field], existing.confidence >= confidence { return }
        candidates[field] = Candidate(value: trimmed, source: source, confidence: confidence)
    }

    private func currentValue(of field: MetadataField, in track: Track) -> String {
        switch field {
        case .artist: return track.artist
        case .title:  return track.title
        case .album:  return track.album
        case .label:  return track.label
        case .year:   return track.year.map(String.init) ?? ""
        }
    }

    /// Titel ohne abschliessende Klammer — so sucht man in Katalogen besser.
    private func bareTitle(_ title: String) -> String {
        let stripped = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        )
        return stripped.isEmpty ? title : stripped
    }
}
