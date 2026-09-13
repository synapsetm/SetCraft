import Foundation
import OSLog

/// Was für einen ganzen Lauf gilt: das im Ordner gelernte Namensschema und der
/// Index für den Zwillings-Abgleich. Einmal bauen, für alle Tracks des Ordners
/// benutzen.
///
/// Der **Ordnername** ist bewusst keine Quelle. Er trägt in gewachsenen
/// Sammlungen zu oft Download-Datum, Sampler-Titel oder gar nichts — und was
/// er liefert, landete dann in Album und Jahr jeder Datei darin.
public struct MetadataContext: Sendable {
    public var pattern: NamingPattern?
    public var duplicates: DuplicateMatcher
    /// Interpreten-Namen aus der Bibliothek (`normalisiert → Schreibweise`).
    /// Damit lässt sich ein Artist-String ohne Trennzeichen wieder in seine
    /// Teile zerlegen — siehe `ArtistNames.split(_:usingKnownNames:)`.
    public var knownArtists: [String: String]

    public init(
        pattern: NamingPattern?,
        duplicates: DuplicateMatcher,
        knownArtists: [String: String] = [:]
    ) {
        self.pattern = pattern
        self.duplicates = duplicates
        self.knownArtists = knownArtists
    }

    /// `folderTracks` sind die Dateien des betrachteten Ordners (Lehrmaterial
    /// für das Schema), `library` alle bekannten Tracks (Kandidaten für den
    /// Zwillings-Abgleich — der darf ordnerübergreifend suchen).
    public static func build(folderTracks: [Track], library: [Track]) -> MetadataContext {
        MetadataContext(
            pattern: PatternLearner.learn(from: folderTracks),
            duplicates: DuplicateMatcher(tracks: library),
            knownArtists: ArtistNames.knownNames(from: library)
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

        // ── Mehrere Interpreten ohne Trennzeichen ──────────────────────────
        // `Luca_Antolini_Andrea_Montorsi` — die Download-Seite hat das Komma
        // gefressen. Wiederherstellen kann das nur Wissen von aussen; das
        // billigste ist die eigene Bibliothek.
        if let artist = candidates[.artist],
           artist.source != .libraryDuplicate,
           !ArtistNames.hasExplicitSeparator(artist.value),
           let parts = ArtistNames.split(artist.value, usingKnownNames: context.knownArtists) {
            notes.append(.artistsSplitUsingLibrary)
            var updated = artist
            // Erst den neuen Wert setzen, dann den alten merken: `remember`
            // lehnt einen Wert ab, der dem aktuellen entspricht.
            updated.value = ArtistNames.join(parts)
            updated.remember(value: artist.value, source: artist.source, confidence: artist.confidence)
            candidates[.artist] = updated
        }

        // ── Stufe 4: Katalog als Gegenprüfung ──────────────────────────────
        var reference: String?
        var catalogError: String?
        if let catalog, options.policy != .off {
            if shouldCheckCatalog(candidates: candidates, parsed: parsed, track: track) {
                let query = CatalogQuery(
                    artist: candidates[.artist]?.value ?? parsed.artist,
                    title: FilenameParser.withoutTrailingBracket(candidates[.title]?.value ?? parsed.title),
                    mixVersion: parsed.mixVersion,
                    catalogNumber: parsed.catalogNumber,
                    year: candidates[.year].flatMap { Int($0.value) },
                    durationSeconds: track.durationSeconds
                )
                if query.isUsable {
                    let outcome = await applyCatalog(
                        catalog,
                        query: query,
                        candidates: &candidates,
                        notes: &notes
                    )
                    reference = outcome.reference
                    catalogError = outcome.errorDescription
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
                isAccepted: current.isEmpty && candidate.confidence >= SuggestionConfidence.autoAcceptThreshold,
                alternatives: candidate.alternatives
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
            catalogReference: reference,
            catalogErrorDescription: catalogError
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
    /// Kandidaten. Liefert die Provenienz des verwendeten Treffers — und, falls
    /// die Abfrage scheiterte, den Grund im Klartext.
    private func applyCatalog(
        _ catalog: CatalogLookup,
        query: CatalogQuery,
        candidates: inout [MetadataField: Candidate],
        notes: inout [ProposalNote]
    ) async -> (reference: String?, errorDescription: String?) {
        let matches: [CatalogMatch]
        do {
            matches = try await catalog.search(query)
        } catch {
            Self.log.notice("Catalog lookup failed for \(query.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            notes.append(.catalogUnavailable)
            return (nil, error.localizedDescription)
        }

        guard let best = matches.first, best.score >= options.minimumCatalogScore else {
            notes.append(.catalogNoMatch)
            return (nil, nil)
        }
        // Zweiter Treffer dicht dahinter → der Nutzer soll zweimal hinschauen.
        let ambiguous = matches.count > 1 && matches[1].score >= best.score - 0.05
        if ambiguous {
            notes.append(.catalogAmbiguous)
        }

        var confirmed = false
        var corrected = false
        var twinKept = false
        var derivedKept = false

        // Sonderfall vertauschte Reihenfolge: ob „Artist - Title" oder
        // „Title - Artist" gilt, kann ein Dateiname allein nicht sagen
        // (`ParsedFilename.orderIsAmbiguous`). Kennt der Katalog unsere beiden
        // Werte über Kreuz, hat er genau diese Frage beantwortet — dann
        // gewinnt er, egal was die Konfliktregel sonst sagen würde.
        let sidesAreSwapped = !best.artist.isEmpty && !best.title.isEmpty
            && TextSimilarity.similarity(candidates[.artist]?.value ?? "", best.title) >= 0.85
            && TextSimilarity.similarity(candidates[.title]?.value ?? "", best.artist) >= 0.85

        // Mehrere gleich gute Treffer: dann ist schon die Auswahl des Releases
        // eine Wette. Das schlägt auf alles durch, was aus diesem Treffer kommt.
        let ambiguityPenalty = ambiguous ? Self.ambiguityPenalty : 0

        // Drei verschiedene Fragen, drei verschiedene Zahlen:
        //
        // • **Bestätigung** — beide Quellen meinen dasselbe. Das ist eine
        //   echte zweite Meinung und darf hoch bewertet werden.
        // • **Lücke gefüllt** — offline war nichts da, es gibt also keinen
        //   Widerspruch. Die Punktzahl des Treffers zählt allein.
        // • **Widerspruch** — zwei Quellen sind sich uneinig, und die
        //   Punktzahl sagt nur, wie gut der Treffer zur *Anfrage* passt, nicht
        //   wer recht hat. Bei einem Bootleg kennt Discogs den Remix gar nicht
        //   und liegt trotz hoher Punktzahl falsch. Deshalb ein Deckel
        //   unterhalb der „hoch"-Schwelle — ein Widerspruch wird nie grün —
        //   und ein Abschlag, der mit der Überzeugung der Offline-Stufe wächst.
        let confirmConfidence = min(0.97, 0.75 + best.score * 0.2) - ambiguityPenalty
        let gapFillConfidence = min(0.90, 0.55 + best.score * 0.35) - ambiguityPenalty

        func contradictionConfidence(displacing existing: Double) -> Double {
            let base = min(Self.contradictionCeiling, 0.5 + best.score * 0.32)
            return max(0.3, base - existing * Self.contradictionPenaltyFactor - ambiguityPenalty)
        }

        func merge(_ field: MetadataField, _ value: String) {
            guard !value.isEmpty else { return }
            guard var existing = candidates[field], !existing.value.isEmpty else {
                candidates[field] = Candidate(value: value, source: .catalog, confidence: gapFillConfidence)
                return
            }

            let agrees = TextSimilarity.similarity(existing.value, value) >= 0.85
            if agrees {
                confirmed = true
            } else {
                corrected = true
            }

            // Ein Zwilling aus der eigenen Bibliothek wird nicht überstimmt.
            // Seine Tags hat der Nutzer selbst gesetzt oder geprüft; ein
            // fremder Katalog ist dagegen keine höhere Instanz. Der
            // Katalogwert bleibt als Alternative erreichbar, und der
            // Widerspruch kostet trotzdem etwas Confidence — uneinig sind
            // sich die Quellen ja.
            if existing.source == .libraryDuplicate {
                if agrees {
                    existing.confidence = max(existing.confidence, confirmConfidence)
                } else {
                    twinKept = true
                    existing.confidence = max(0.6, existing.confidence - Self.twinDisagreementPenalty)
                    existing.remember(value: value, source: .catalog, confidence: gapFillConfidence)
                }
                candidates[field] = existing
                return
            }
            // Bei Übereinstimmung zählt die **Schreibweise des Katalogs**: beide
            // meinen denselben Track, und die Katalogfassung setzt die Klammern
            // richtig. „Mama India Outside The (Universe Remix)" und „Mama
            // India (Outside The Universe Remix)" sind für unser
            // Ähnlichkeitsmass identisch; nur eine gehört in den Tag.
            //
            // Bei Widerspruch entscheidet `catalogWinsContradiction` — und da
            // gewinnt im Regelfall der Dateiname.
            let catalogWins = agrees
                || sidesAreSwapped
                || Self.catalogWinsContradiction(field: field, ours: existing.value, theirs: value)

            guard catalogWins else {
                derivedKept = true
                existing.confidence = max(0.6, existing.confidence - Self.twinDisagreementPenalty)
                existing.remember(value: value, source: .catalog, confidence: gapFillConfidence)
                candidates[field] = existing
                return
            }

            var replacement = Candidate(
                value: value,
                source: .catalog,
                confidence: agrees
                    ? max(existing.confidence, confirmConfidence)
                    : contradictionConfidence(displacing: existing.confidence)
            )
            replacement.displaced = existing.displaced
            replacement.remember(value: existing.value, source: existing.source, confidence: existing.confidence)
            candidates[field] = replacement
        }

        merge(.artist, best.artist)
        merge(.title, best.title)
        merge(.album, best.album)
        merge(.label, best.label)
        if let year = best.year { merge(.year, String(year)) }

        if twinKept {
            notes.append(.libraryTwinKept)
        } else if derivedKept {
            notes.append(.catalogOverruled)
        } else if corrected {
            notes.append(.catalogCorrected)
        } else if confirmed {
            notes.append(.catalogConfirmed)
        }
        return (best.reference.isEmpty ? nil : best.reference, nil)
    }

    // MARK: - Helpers

    /// Wessen Wert bei einem Widerspruch vorgeschlagen wird.
    ///
    /// Grundhaltung: **der hergeleitete Wert gewinnt.** Der Dateiname
    /// beschreibt die Datei, die tatsächlich vorliegt; der Katalog beschreibt
    /// einen Eintrag, der eine *andere Fassung* sein kann. Bei Bootlegs, Edits
    /// und Promos kennt Discogs die Fassung gar nicht und trifft trotzdem
    /// hervorragend auf das Original — das ist kein Grund, den richtigen Titel
    /// zu überschreiben.
    ///
    /// Zwei Ausnahmen, beide mit Belegen aus echten Läufen:
    ///
    /// 1. **Schreibweise.** Die Werte sind fast gleich. Dann hat der Katalog
    ///    das Zeichen, das die Download-Seite verschluckt hat: aus „Ikøn" wird
    ///    im Dateinamen „IK N", und nur der Katalog kann das zurückgeben.
    /// 2. **Ergänzung.** Unser Titel trägt keine Mix-Bezeichnung, der Katalog
    ///    schon. Dann fehlt uns Information, statt dass wir widersprechen.
    ///
    /// Umgekehrt gilt: tragen **beide** eine Mix-Bezeichnung und sind die
    /// verschieden, reden sie von zwei Fassungen — dann zählt unsere, denn
    /// die beschreibt die Datei.
    static func catalogWinsContradiction(field: MetadataField, ours: String, theirs: String) -> Bool {
        if field == .title {
            let ourMix = FilenameParser.mixVersion(in: ours) ?? ""
            let theirMix = FilenameParser.mixVersion(in: theirs) ?? ""

            if !ourMix.isEmpty, !theirMix.isEmpty {
                // Verschiedene Fassungen → unsere. Nur wenn die Bezeichnungen
                // im Kern dieselben sind, ist es eine Schreibweisenfrage.
                guard TextSimilarity.similarity(ourMix, theirMix) >= 0.7 else { return false }
            } else if !ourMix.isEmpty {
                return false            // wir sind spezifischer als der Katalog
            } else if !theirMix.isEmpty {
                return true             // der Katalog kennt die Fassung, wir nicht
            }
        }
        return TextSimilarity.similarity(ours, theirs) >= Self.spellingVariantThreshold
    }

    /// Ab dieser Ähnlichkeit halten wir einen abweichenden Katalogwert für
    /// dieselbe Bezeichnung in sauberer Schreibweise statt für einen anderen
    /// Track.
    static let spellingVariantThreshold = 0.6

    /// Obergrenze für einen Wert, der einer Offline-Stufe **widerspricht**.
    /// Liegt bewusst unter `SuggestionConfidence`-Schwelle für „hoch": ein
    /// Widerspruch ist nie eine Gewissheit, egal wie gut der Katalogtreffer
    /// zur Anfrage passt.
    static let contradictionCeiling = 0.82

    /// Wie stark die Überzeugung der überstimmten Stufe den Widerspruch
    /// verbilligt bzw. verteuert. Wer ein einstimmiges Ordner-Schema oder
    /// einen getaggten Zwilling überstimmt, muss mehr mitbringen als wer einen
    /// mehrdeutigen Dateinamen überstimmt.
    static let contradictionPenaltyFactor = 0.12

    /// Abschlag, wenn mehrere Katalog-Treffer gleich gut passten.
    static let ambiguityPenalty = 0.05

    /// Abschlag auf den Wert eines Bibliotheks-Zwillings, dem der Katalog
    /// widerspricht. Der Zwilling bleibt, aber sicher ist die Sache nicht mehr.
    static let twinDisagreementPenalty = 0.1

    /// Ein Kandidat, solange noch Stufen folgen können — samt der Werte, die
    /// unterwegs verdrängt wurden. Die gehen nicht verloren: im Review-Sheet
    /// kann der Nutzer zurückschalten, wenn die „bessere" Stufe danebenlag.
    struct Candidate: Sendable {
        var value: String
        var source: SuggestionSource
        var confidence: Double
        var displaced: [FieldSuggestion.Alternative] = []

        /// Legt einen Wert zu den Verworfenen, ohne Dubletten.
        mutating func remember(value: String, source: SuggestionSource, confidence: Double) {
            guard !value.isEmpty, value != self.value else { return }
            guard !displaced.contains(where: { $0.value == value }) else { return }
            displaced.append(.init(value: value, source: source, confidence: confidence))
        }

        /// Verworfene, beste zuerst.
        var alternatives: [FieldSuggestion.Alternative] {
            displaced
                .filter { $0.value != value }
                .sorted { $0.confidence > $1.confidence }
        }
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

        guard var existing = candidates[field] else {
            candidates[field] = Candidate(value: trimmed, source: source, confidence: confidence)
            return
        }
        if existing.confidence >= confidence {
            // Schwächerer Vorschlag: trotzdem behalten, als Alternative.
            existing.remember(value: trimmed, source: source, confidence: confidence)
            candidates[field] = existing
            return
        }
        var replacement = Candidate(value: trimmed, source: source, confidence: confidence)
        replacement.displaced = existing.displaced
        replacement.remember(value: existing.value, source: existing.source, confidence: existing.confidence)
        candidates[field] = replacement
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
}
