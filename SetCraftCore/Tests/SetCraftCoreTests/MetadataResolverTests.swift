import XCTest
@testable import SetCraftCore

// MARK: - Helpers

private func makeTrack(
    _ path: String,
    title: String = "",
    artist: String = "",
    album: String = "",
    label: String = "",
    year: Int? = nil,
    duration: TimeInterval = 0,
    fileSize: Int64? = nil
) -> Track {
    Track(
        url: URL(fileURLWithPath: path),
        title: title,
        artist: artist,
        album: album,
        durationSeconds: duration,
        year: year,
        label: label,
        fileSize: fileSize
    )
}

/// Katalog-Doppel: merkt sich die Anfragen, liefert feste Treffer.
private actor FakeCatalog: CatalogLookup {
    private(set) var queries: [CatalogQuery] = []
    private let matches: [CatalogMatch]
    private let failure: Error?

    init(matches: [CatalogMatch] = [], failure: Error? = nil) {
        self.matches = matches
        self.failure = failure
    }

    func search(_ query: CatalogQuery) async throws -> [CatalogMatch] {
        queries.append(query)
        if let failure { throw failure }
        return matches
    }

    func recordedQueries() -> [CatalogQuery] { queries }
}

private struct CatalogDown: Error {}

// MARK: - PatternLearner

final class PatternLearnerTests: XCTestCase {

    func test_artistFirstFolder_isLearned() {
        let tracks = [
            makeTrack("/m/Len Faki - Mekong Delta.mp3", title: "Mekong Delta", artist: "Len Faki"),
            makeTrack("/m/Marcel Dettmann - Seduction.mp3", title: "Seduction", artist: "Marcel Dettmann"),
            makeTrack("/m/Ben Klock - Subzero.mp3", title: "Subzero", artist: "Ben Klock")
        ]
        let pattern = PatternLearner.learn(from: tracks)
        XCTAssertEqual(pattern?.layout, .artistFirst)
        XCTAssertEqual(pattern?.sampleCount, 3)
        XCTAssertEqual(pattern?.agreement ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertTrue(pattern?.isTrustworthy ?? false)
    }

    func test_titleFirstFolder_isLearned() {
        let tracks = [
            makeTrack("/m/Mekong Delta - Len Faki.mp3", title: "Mekong Delta", artist: "Len Faki"),
            makeTrack("/m/Seduction - Marcel Dettmann.mp3", title: "Seduction", artist: "Marcel Dettmann"),
            makeTrack("/m/Subzero - Ben Klock.mp3", title: "Subzero", artist: "Ben Klock")
        ]
        XCTAssertEqual(PatternLearner.learn(from: tracks)?.layout, .titleFirst)
    }

    func test_tooFewSamples_isNotTrustworthy() {
        let tracks = [
            makeTrack("/m/Len Faki - Mekong Delta.mp3", title: "Mekong Delta", artist: "Len Faki"),
            makeTrack("/m/Ben Klock - Subzero.mp3", title: "Subzero", artist: "Ben Klock")
        ]
        XCTAssertFalse(PatternLearner.learn(from: tracks)?.isTrustworthy ?? false)
    }

    func test_untaggedTracks_contributeNoVotes() {
        let tracks = [
            makeTrack("/m/Len Faki - Mekong Delta.mp3"),
            makeTrack("/m/Ben Klock - Subzero.mp3")
        ]
        XCTAssertNil(PatternLearner.learn(from: tracks))
    }

    func test_filenamesUnrelatedToTags_contributeNoVotes() {
        let tracks = [
            makeTrack("/m/track01.mp3", title: "Mekong Delta", artist: "Len Faki"),
            makeTrack("/m/track02.mp3", title: "Subzero", artist: "Ben Klock"),
            makeTrack("/m/track03.mp3", title: "Seduction", artist: "Marcel Dettmann")
        ]
        XCTAssertNil(PatternLearner.learn(from: tracks))
    }

    func test_apply_titleFirst_swapsSidesAndResolvesOrder() {
        let pattern = NamingPattern(layout: .titleFirst, sampleCount: 5, agreement: 1.0)
        let parsed = FilenameParser.parse(stem: "Rolling Sevens - Skudge")
        let aligned = PatternLearner.apply(pattern, to: parsed)
        XCTAssertEqual(aligned.artist, "Skudge")
        XCTAssertEqual(aligned.title, "Rolling Sevens")
        XCTAssertFalse(aligned.orderIsAmbiguous)
    }

    func test_apply_artistFirst_resolvesOrderWithoutSwap() {
        let pattern = NamingPattern(layout: .artistFirst, sampleCount: 5, agreement: 1.0)
        let parsed = FilenameParser.parse(stem: "Skudge - Rolling Sevens")
        let aligned = PatternLearner.apply(pattern, to: parsed)
        XCTAssertEqual(aligned.artist, "Skudge")
        XCTAssertFalse(aligned.orderIsAmbiguous)
    }

    func test_apply_untrustworthyPattern_changesNothing() {
        let pattern = NamingPattern(layout: .titleFirst, sampleCount: 2, agreement: 1.0)
        let parsed = FilenameParser.parse(stem: "Skudge - Rolling Sevens")
        XCTAssertEqual(PatternLearner.apply(pattern, to: parsed), parsed)
    }
}

// MARK: - DuplicateMatcher

final class DuplicateMatcherTests: XCTestCase {

    func test_identicalDurationAndSize_isIdenticalFile() {
        let twin = makeTrack("/lib/Skudge - Phantom.mp3", title: "Phantom", artist: "Skudge",
                             duration: 371, fileSize: 8_912_345)
        let orphan = makeTrack("/dl/track07.mp3", duration: 371, fileSize: 8_912_345)
        let match = DuplicateMatcher(tracks: [twin]).match(for: orphan)
        XCTAssertEqual(match?.reason, .identicalFile)
        XCTAssertEqual(match?.track.title, "Phantom")
    }

    func test_similarNameAndDuration_matches() {
        let twin = makeTrack("/lib/x.mp3", title: "Phantom", artist: "Skudge", duration: 371)
        let orphan = makeTrack("/dl/Skudge - Phantom.mp3", duration: 372)
        XCTAssertEqual(DuplicateMatcher(tracks: [twin]).match(for: orphan)?.reason, .durationAndName)
    }

    func test_sameDurationDifferentTrack_isNoMatch() {
        let twin = makeTrack("/lib/x.mp3", title: "Phantom", artist: "Skudge", duration: 371)
        let orphan = makeTrack("/dl/Rhythim Is Rhythim - Strings Of Life.mp3", duration: 371)
        XCTAssertNil(DuplicateMatcher(tracks: [twin]).match(for: orphan))
    }

    func test_durationTooFarApart_isNoMatch() {
        let twin = makeTrack("/lib/x.mp3", title: "Phantom", artist: "Skudge", duration: 371)
        let orphan = makeTrack("/dl/Skudge - Phantom.mp3", duration: 420)
        XCTAssertNil(DuplicateMatcher(tracks: [twin]).match(for: orphan))
    }

    func test_untaggedCandidates_areIgnored() {
        let twin = makeTrack("/lib/Skudge - Phantom.mp3", duration: 371, fileSize: 42)
        let orphan = makeTrack("/dl/other.mp3", duration: 371, fileSize: 42)
        XCTAssertNil(DuplicateMatcher(tracks: [twin]).match(for: orphan))
    }

    func test_sameFile_isNeverItsOwnTwin() {
        let track = makeTrack("/lib/Skudge - Phantom.mp3", title: "Phantom", artist: "Skudge",
                              duration: 371, fileSize: 42)
        XCTAssertNil(DuplicateMatcher(tracks: [track]).match(for: track))
    }
}

// MARK: - Kette

final class MetadataResolverChainTests: XCTestCase {

    private func emptyContext() -> MetadataContext {
        MetadataContext(pattern: nil, duplicates: DuplicateMatcher(tracks: []))
    }

    func test_cleanFilename_offline_proposesArtistAndTitle() async {
        let resolver = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let track = makeTrack("/m/Len Faki - Mekong Delta (Extended Mix).mp3")
        let proposal = await resolver.proposal(for: track, context: emptyContext())

        XCTAssertEqual(proposal.suggestion(for: .artist)?.value, "Len Faki")
        XCTAssertEqual(proposal.suggestion(for: .title)?.value, "Mekong Delta (Extended Mix)")
        XCTAssertTrue(proposal.suggestion(for: .title)?.isAccepted ?? false)
        XCTAssertTrue(proposal.hasChanges)
    }

    func test_existingCorrectTags_produceNoChanges() async {
        let resolver = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let track = makeTrack("/m/Len Faki - Mekong Delta.mp3", title: "Mekong Delta", artist: "Len Faki")
        let proposal = await resolver.proposal(for: track, context: emptyContext())
        XCTAssertFalse(proposal.hasChanges)
    }

    func test_differingTag_isProposedButNotPreselected() async {
        let resolver = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let track = makeTrack("/m/Len Faki - Mekong Delta.mp3", title: "mekongdelta", artist: "Len Faki")
        let proposal = await resolver.proposal(for: track, context: emptyContext())
        let title = proposal.suggestion(for: .title)
        XCTAssertEqual(title?.value, "Mekong Delta")
        XCTAssertTrue(title?.isOverwrite ?? false)
        XCTAssertFalse(title?.isAccepted ?? true)
    }

    func test_folderPattern_swapsAndRaisesConfidence() async {
        let siblings = (1...4).map { index in
            makeTrack("/m/Title\(index) - Artist\(index).mp3", title: "Title\(index)", artist: "Artist\(index)")
        }
        let context = MetadataContext.build(folderTracks: siblings, library: siblings)
        let resolver = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let track = makeTrack("/m/Rolling Sevens - Skudge.mp3")
        let proposal = await resolver.proposal(for: track, context: context)

        XCTAssertEqual(proposal.suggestion(for: .artist)?.value, "Skudge")
        XCTAssertEqual(proposal.suggestion(for: .title)?.value, "Rolling Sevens")
        XCTAssertEqual(proposal.suggestion(for: .title)?.source, .folderPattern)
        XCTAssertTrue(proposal.notes.contains(.folderPatternSwapped))
    }

    func test_libraryDuplicate_winsOverFilename() async {
        let twin = makeTrack("/lib/x.mp3", title: "Phantom", artist: "Skudge",
                             album: "Phantom EP", duration: 371, fileSize: 42)
        let orphan = makeTrack("/dl/unknown artist - phantom.mp3", duration: 371, fileSize: 42)
        let context = MetadataContext(pattern: nil, duplicates: DuplicateMatcher(tracks: [twin]))
        let resolver = MetadataResolver(options: .init(policy: .off))
        let proposal = await resolver.proposal(for: orphan, context: context)

        XCTAssertEqual(proposal.suggestion(for: .artist)?.value, "Skudge")
        XCTAssertEqual(proposal.suggestion(for: .artist)?.source, .libraryDuplicate)
        XCTAssertEqual(proposal.suggestion(for: .album)?.value, "Phantom EP")
        XCTAssertTrue(proposal.notes.contains(.identicalFileFound))
    }

    func test_folderName_contributesNothing() async {
        // Der Ordnername ist bewusst keine Quelle: „Daft Punk - Discovery
        // (2001)" wuerde sonst Album und Jahr an jede Datei darin haengen,
        // und in Download-Ordnern steht dort Unsinn.
        let context = MetadataContext.build(folderTracks: [], library: [])
        let resolver = MetadataResolver(options: .init(policy: .off))
        let track = makeTrack("/m/Daft Punk - Discovery (2001)/04 - Crescendolls.mp3")
        let proposal = await resolver.proposal(for: track, context: context)

        XCTAssertNil(proposal.suggestion(for: .album))
        XCTAssertNil(proposal.suggestion(for: .label))
        XCTAssertEqual(proposal.suggestion(for: .title)?.value, "Crescendolls")
    }

    // MARK: Katalog-Policy

    func test_policyOff_neverAsksCatalog() async {
        let catalog = FakeCatalog()
        let resolver = MetadataResolver(catalog: catalog, options: .init(fields: MetadataField.core, policy: .off))
        _ = await resolver.proposal(for: makeTrack("/m/untitled.mp3"), context: emptyContext())
        let queries = await catalog.recordedQueries()
        XCTAssertTrue(queries.isEmpty)
    }

    func test_whenUncertain_skipsConfidentTrack() async {
        let catalog = FakeCatalog()
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .whenUncertain)
        )
        // Mix-Klammer klärt die Reihenfolge → Confidence 0.75 … unter der
        // Schwelle von 0.8 wäre das noch unsicher, das Ordner-Schema hebt es.
        let siblings = (1...4).map { index in
            makeTrack("/m/Artist\(index) - Title\(index).mp3", title: "Title\(index)", artist: "Artist\(index)")
        }
        let context = MetadataContext.build(folderTracks: siblings, library: [])
        _ = await resolver.proposal(for: makeTrack("/m/Skudge - Phantom.mp3"), context: context)

        let queries = await catalog.recordedQueries()
        XCTAssertTrue(queries.isEmpty, "Sicherer Offline-Treffer darf kein Request kosten")
    }

    func test_whenUncertain_asksForAmbiguousOrder() async {
        let catalog = FakeCatalog()
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .whenUncertain)
        )
        _ = await resolver.proposal(for: makeTrack("/m/Innervisions - Howling.mp3"), context: emptyContext())
        let queries = await catalog.recordedQueries()
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?.artist, "Innervisions")
        XCTAssertEqual(queries.first?.title, "Howling")
    }

    func test_whenUncertain_asksWhenRequestedFieldStaysEmpty() async {
        let catalog = FakeCatalog()
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: [.artist, .title, .label], policy: .whenUncertain)
        )
        _ = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta (Extended Mix).mp3"),
            context: emptyContext()
        )
        let queries = await catalog.recordedQueries()
        XCTAssertEqual(queries.count, 1, "Label fehlt noch → Katalog ist die einzige Quelle")
    }

    func test_always_asksEvenForConfidentTrack() async {
        let catalog = FakeCatalog()
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        _ = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta (Extended Mix).mp3"),
            context: emptyContext()
        )
        let queries = await catalog.recordedQueries()
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?.title, "Mekong Delta", "Mix-Klammer gehört nicht in die Suchanfrage")
    }

    func test_catalogConfirmation_raisesConfidence() async {
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Len Faki", title: "Mekong Delta", score: 0.95, reference: "discogs:release/42#A1")
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta.mp3"),
            context: emptyContext()
        )
        XCTAssertTrue(proposal.notes.contains(.catalogConfirmed))
        XCTAssertEqual(proposal.confidenceLevel, .high)
        XCTAssertEqual(proposal.catalogReference, "discogs:release/42#A1")
    }

    func test_catalogResolvesSwappedSides() async {
        // „Title - Artist" ist aus dem Dateinamen nicht entscheidbar. Kennt der
        // Katalog beide Werte über Kreuz, hat er die Frage beantwortet — hier
        // gewinnt er, obwohl die Werte sich widersprechen.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Rhythim Is Rhythim", title: "Strings Of Life", score: 0.9,
                         reference: "discogs:release/7#A")
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .whenUncertain)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Strings Of Life - Rhythim Is Rhythim.mp3"),
            context: emptyContext()
        )
        XCTAssertEqual(proposal.suggestion(for: .artist)?.value, "Rhythim Is Rhythim")
        XCTAssertEqual(proposal.suggestion(for: .title)?.value, "Strings Of Life")
        XCTAssertEqual(proposal.suggestion(for: .artist)?.source, .catalog)
        XCTAssertTrue(proposal.notes.contains(.catalogCorrected))
    }

    func test_weakCatalogMatch_isIgnored() async {
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Someone Else", title: "Other Track", score: 0.3)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta.mp3"),
            context: emptyContext()
        )
        XCTAssertTrue(proposal.notes.contains(.catalogNoMatch))
        XCTAssertEqual(proposal.suggestion(for: .artist)?.value, "Len Faki")
    }

    func test_twoCloseMatches_areFlaggedAsAmbiguous() async {
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Skudge", title: "Phantom", score: 0.9),
            CatalogMatch(artist: "Skudge", title: "Phantom (Remix)", score: 0.88)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Skudge - Phantom.mp3"),
            context: emptyContext()
        )
        XCTAssertTrue(proposal.notes.contains(.catalogAmbiguous))
    }

    func test_catalogFailure_keepsOfflineResult() async {
        let catalog = FakeCatalog(failure: CatalogDown())
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta.mp3"),
            context: emptyContext()
        )
        XCTAssertTrue(proposal.notes.contains(.catalogUnavailable))
        XCTAssertEqual(proposal.suggestion(for: .artist)?.value, "Len Faki")
    }

    func test_catalogConfirmation_takesTheCatalogSpelling() async {
        // Beide meinen denselben Track — unser Ähnlichkeitsmass sieht dieselben
        // Tokens. Nur eine der beiden Klammersetzungen ist richtig, und das ist
        // die aus dem Katalog.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Technical Hitch",
                         title: "Mama India (Outside The Universe Remix)",
                         score: 0.9, reference: "discogs:release/1#A")
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Technical Hitch - Mama India Outside The Universe Remix.mp3"),
            context: emptyContext()
        )
        let title = try! XCTUnwrap(proposal.suggestion(for: .title))
        XCTAssertEqual(title.value, "Mama India (Outside The Universe Remix)")
        XCTAssertEqual(title.source, .catalog)
        XCTAssertTrue(proposal.notes.contains(.catalogConfirmed))
        XCTAssertTrue(
            title.alternatives.contains { $0.value == "Mama India Outside The (Universe Remix)" },
            "Der hergeleitete Wert bleibt als Alternative erhalten"
        )
    }

    func test_derivedValueAndCatalogValue_areInterchangeable() async {
        // Bootleg: Discogs kennt den Remix nicht. Unser Wert steht vorne, der
        // Katalogwert daneben — und der Wechsel geht in beide Richtungen.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Paul van Dyk",
                         title: "For An Angel (Terry Lee Brown Jnr Remix)",
                         score: 0.8, reference: "discogs:release/2#B")
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        var proposal = await resolver.proposal(
            for: makeTrack("/m/Paul van Dyk - For An Angel Phaxe Remix.mp3"),
            context: emptyContext()
        )
        var title = try! XCTUnwrap(proposal.suggestion(for: .title))
        XCTAssertEqual(title.value, "For An Angel (Phaxe Remix)")
        let fromCatalog = try! XCTUnwrap(title.alternatives.first { $0.source == .catalog })

        title.select(fromCatalog)
        XCTAssertEqual(title.value, "For An Angel (Terry Lee Brown Jnr Remix)")
        XCTAssertTrue(title.alternatives.contains { $0.value.contains("Phaxe") })

        proposal.fields[0] = title
        XCTAssertEqual(proposal.suggestion(for: title.field)?.value,
                       "For An Angel (Terry Lee Brown Jnr Remix)")
    }

    func test_weakerStage_survivesAsAlternative() async {
        // Der Zwilling schlägt den Dateinamen — dessen Wert bleibt trotzdem da.
        let twin = makeTrack("/lib/x.mp3", title: "Phantom", artist: "Skudge",
                             duration: 371, fileSize: 42)
        let orphan = makeTrack("/dl/Skudge - Phantom Remastered.mp3", duration: 371, fileSize: 42)
        let context = MetadataContext(pattern: nil, duplicates: DuplicateMatcher(tracks: [twin]))
        let resolver = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let proposal = await resolver.proposal(for: orphan, context: context)

        let title = try! XCTUnwrap(proposal.suggestion(for: .title))
        XCTAssertEqual(title.value, "Phantom")
        XCTAssertTrue(title.alternatives.contains { $0.value.contains("Remastered") })
    }

    func test_manualValue_takesOverAndKeepsSuggestion() async {
        let resolver = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta.mp3"),
            context: emptyContext()
        )
        var title = try! XCTUnwrap(proposal.suggestion(for: .title))
        title.setManualValue("Mekong Delta (Dub)")

        XCTAssertEqual(title.value, "Mekong Delta (Dub)")
        XCTAssertEqual(title.source, .manual)
        XCTAssertEqual(title.confidence, 1.0, accuracy: 0.0001)
        XCTAssertTrue(title.alternatives.contains { $0.value == "Mekong Delta" })
    }

    func test_catalog_doesNotOverrideALibraryTwin() async {
        // Die Tags des Zwillings hat der Nutzer selbst gesetzt — ein fremder
        // Katalog ist keine höhere Instanz.
        let twin = makeTrack("/lib/x.mp3", title: "Phantom (Dub Edit)", artist: "Skudge",
                             duration: 371, fileSize: 42)
        let orphan = makeTrack("/dl/skudge - phantom.mp3", duration: 371, fileSize: 42)
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Skudge", title: "Phantom (Original Mix)", score: 0.95)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let context = MetadataContext(pattern: nil, duplicates: DuplicateMatcher(tracks: [twin]))
        let proposal = await resolver.proposal(for: orphan, context: context)

        let title = try! XCTUnwrap(proposal.suggestion(for: .title))
        XCTAssertEqual(title.value, "Phantom (Dub Edit)")
        XCTAssertEqual(title.source, .libraryDuplicate)
        XCTAssertTrue(proposal.notes.contains(.libraryTwinKept))
        XCTAssertTrue(title.alternatives.contains { $0.value == "Phantom (Original Mix)" },
                      "Der Katalogwert bleibt als Alternative erreichbar")
    }

    func test_catalogDisagreement_costsTheTwinSomeConfidence() async {
        let twin = makeTrack("/lib/x.mp3", title: "Phantom (Dub Edit)", artist: "Skudge",
                             duration: 371, fileSize: 42)
        let orphan = makeTrack("/dl/skudge - phantom.mp3", duration: 371, fileSize: 42)
        let context = MetadataContext(pattern: nil, duplicates: DuplicateMatcher(tracks: [twin]))

        let offline = MetadataResolver(options: .init(fields: MetadataField.core, policy: .off))
        let undisputed = await offline.proposal(for: orphan, context: context)

        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Skudge", title: "Phantom (Original Mix)", score: 0.95)
        ])
        let checked = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let disputed = await checked.proposal(for: orphan, context: context)

        let before = try! XCTUnwrap(undisputed.suggestion(for: .title)?.confidence)
        let after = try! XCTUnwrap(disputed.suggestion(for: .title)?.confidence)
        XCTAssertLessThan(after, before, "Uneinigkeit bleibt Uneinigkeit, auch wenn der Zwilling gewinnt")
    }

    func test_catalogAgreement_raisesTheTwinsConfidence() async {
        let twin = makeTrack("/lib/x.mp3", title: "Phantom", artist: "Skudge",
                             duration: 371, fileSize: 42)
        let orphan = makeTrack("/dl/skudge - phantom.mp3", duration: 371, fileSize: 42)
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Skudge", title: "Phantom", score: 0.95)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let context = MetadataContext(pattern: nil, duplicates: DuplicateMatcher(tracks: [twin]))
        let proposal = await resolver.proposal(for: orphan, context: context)

        let title = try! XCTUnwrap(proposal.suggestion(for: .title))
        XCTAssertEqual(title.value, "Phantom")
        XCTAssertEqual(SuggestionConfidence.level(title.confidence), .high)
        XCTAssertTrue(proposal.notes.contains(.catalogConfirmed))
    }

    // MARK: Confidence

    /// Kontext mit einem einstimmigen, gut belegten Ordner-Schema.
    private func confidentPatternContext() -> MetadataContext {
        let siblings = (1...5).map { index in
            makeTrack("/m/Artist\(index) - Title\(index).mp3", title: "Title\(index)", artist: "Artist\(index)")
        }
        return MetadataContext.build(folderTracks: siblings, library: [])
    }

    func test_contradiction_keepsTheDerivedValue() async {
        // Bootleg-Lage: der Dateiname hat recht, Discogs liefert einen sehr gut
        // passenden Treffer auf eine andere Fassung.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Paul van Dyk",
                         title: "For An Angel (Terry Lee Brown Jnr Remix)",
                         score: 0.95, reference: "discogs:release/2#B")
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Paul van Dyk - For An Angel Phaxe Remix.mp3"),
            context: confidentPatternContext()
        )
        let title = try! XCTUnwrap(proposal.suggestion(for: .title))
        XCTAssertEqual(title.value, "For An Angel (Phaxe Remix)")
        XCTAssertEqual(title.source, .folderPattern)
        XCTAssertTrue(proposal.notes.contains(.catalogOverruled))
        XCTAssertTrue(title.alternatives.contains { $0.value.contains("Terry Lee Brown") },
                      "Der Katalogwert bleibt als Alternative erreichbar")
        XCTAssertNotEqual(SuggestionConfidence.level(title.confidence), .high,
                          "Uneinigkeit bleibt Uneinigkeit")
    }

    func test_catalogWins_whenItLooksLikeASpellingFix() async {
        // Die Download-Seite hat das ø verschluckt — nur der Katalog kann es
        // zurückgeben.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Ikøn", title: "Higher Dimension", score: 0.9)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/IK N - Higher Dimension.mp3"),
            context: emptyContext()
        )
        let artist = try! XCTUnwrap(proposal.suggestion(for: .artist))
        XCTAssertEqual(artist.value, "Ikøn")
        XCTAssertEqual(artist.source, .catalog)
        XCTAssertTrue(artist.alternatives.contains { $0.value == "IK N" })
    }

    func test_catalogWins_whenItAddsAMissingMixVersion() async {
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Len Faki", title: "Mekong Delta (Extended Mix)", score: 0.9)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta.mp3"),
            context: emptyContext()
        )
        XCTAssertEqual(proposal.suggestion(for: .title)?.value, "Mekong Delta (Extended Mix)")
    }

    func test_derivedWins_whenItIsMoreSpecificThanTheCatalog() async {
        // Unsere Fassung nennt den Remix, die Tracklist nicht — dann sind wir
        // spezifischer, nicht falsch.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Len Faki", title: "Mekong Delta", score: 0.9)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta Phaxe Remix.mp3"),
            context: emptyContext()
        )
        XCTAssertEqual(proposal.suggestion(for: .title)?.value, "Mekong Delta (Phaxe Remix)")
    }

    func test_contradictionRule_inIsolation() {
        typealias R = MetadataResolver
        // Fassungen verschieden → unsere.
        XCTAssertFalse(R.catalogWinsContradiction(
            field: .title, ours: "Track (Phaxe Remix)", theirs: "Track (Astrix Remix)"))
        // Fassung nur bei uns → unsere.
        XCTAssertFalse(R.catalogWinsContradiction(
            field: .title, ours: "Track (Phaxe Remix)", theirs: "Track"))
        // Fassung nur im Katalog → seine.
        XCTAssertTrue(R.catalogWinsContradiction(
            field: .title, ours: "Track", theirs: "Track (Original Mix)"))
        // Artist: Schreibweise → seine.
        XCTAssertTrue(R.catalogWinsContradiction(field: .artist, ours: "IK N", theirs: "Ikøn"))
        // Artist: wildfremd → unsere.
        XCTAssertFalse(R.catalogWinsContradiction(field: .artist, ours: "Skudge", theirs: "Planewalker"))
    }

    func test_contradiction_costsMoreAgainstAStrongerStage() async {
        // Schreibweisen-Fall (der Katalog gewinnt) — aber je überzeugter die
        // überstimmte Stufe war, desto weniger sicher ist das Ergebnis.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Ikøn", title: "Higher Dimension", score: 0.9)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let track = makeTrack("/m/IK N - Higher Dimension.mp3")

        let weak = await resolver.proposal(for: track, context: emptyContext())
        let strong = await resolver.proposal(for: track, context: confidentPatternContext())

        let weakConfidence = try! XCTUnwrap(weak.suggestion(for: .artist)?.confidence)
        let strongConfidence = try! XCTUnwrap(strong.suggestion(for: .artist)?.confidence)
        XCTAssertLessThan(strongConfidence, weakConfidence,
                          "Ein einstimmiges Ordner-Schema zu überstimmen muss teurer sein")
    }

    func test_gapFill_mayReachHighConfidence() async {
        // Kein Trenner im Namen → offline gibt es keinen Artist. Der Katalog
        // widerspricht also niemandem, er füllt eine Lücke.
        let catalog = FakeCatalog(matches: [
            CatalogMatch(artist: "Burial", title: "Archangel", score: 1.0)
        ])
        let resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: MetadataField.core, policy: .always)
        )
        let proposal = await resolver.proposal(
            for: makeTrack("/m/Archangel.mp3"),
            context: emptyContext()
        )
        let artist = try! XCTUnwrap(proposal.suggestion(for: .artist))
        XCTAssertEqual(artist.value, "Burial")
        XCTAssertEqual(SuggestionConfidence.level(artist.confidence), .high)
    }

    func test_ambiguousMatches_lowerTheConfidence() async {
        let single = FakeCatalog(matches: [
            CatalogMatch(artist: "Burial", title: "Archangel", score: 0.95)
        ])
        let several = FakeCatalog(matches: [
            CatalogMatch(artist: "Burial", title: "Archangel", score: 0.95),
            CatalogMatch(artist: "Burial", title: "Archangel (Edit)", score: 0.94)
        ])
        let track = makeTrack("/m/Archangel.mp3")

        func confidence(_ catalog: CatalogLookup) async -> Double {
            let resolver = MetadataResolver(
                catalog: catalog,
                options: .init(fields: MetadataField.core, policy: .always)
            )
            let proposal = await resolver.proposal(for: track, context: emptyContext())
            return proposal.suggestion(for: .artist)?.confidence ?? 0
        }

        let clear = await confidence(single)
        let murky = await confidence(several)
        XCTAssertLessThan(murky, clear)
    }

    // MARK: Anwenden

    func test_applied_writesOnlyAcceptedFields() async {
        let resolver = MetadataResolver(options: .init(policy: .off))
        var proposal = await resolver.proposal(
            for: makeTrack("/m/Len Faki - Mekong Delta.mp3", album: "Keep Me"),
            context: emptyContext()
        )
        // Alles abwählen, nur den Titel übernehmen.
        for index in proposal.fields.indices {
            proposal.fields[index].isAccepted = proposal.fields[index].field == .title
        }
        let result = proposal.applied(to: proposal.track)
        XCTAssertEqual(result.title, "Mekong Delta")
        XCTAssertEqual(result.artist, "", "Artist war nicht angehakt")
        XCTAssertEqual(result.album, "Keep Me")
    }

    func test_applied_leavesAudioFieldsUntouched() async {
        var base = makeTrack("/m/Len Faki - Mekong Delta.mp3", duration: 400)
        base.bpm = 131.5
        base.key = CamelotKey("8A")
        base.rating = Rating(stars: 4)
        base.comment = "peak time"

        let resolver = MetadataResolver(options: .init(policy: .off))
        let proposal = await resolver.proposal(for: base, context: emptyContext())
        let result = proposal.applied(to: base)

        XCTAssertEqual(result.bpm, 131.5)
        XCTAssertEqual(result.key?.description, "8A")
        XCTAssertEqual(result.rating.stars, 4)
        XCTAssertEqual(result.comment, "peak time")
    }
}
