import XCTest
@testable import SetCraftCore

final class FilenameParserTests: XCTestCase {

    // MARK: - Standardfälle

    func test_artistDashTitle() {
        let p = FilenameParser.parse(stem: "The Persuader - Östermalm")
        XCTAssertEqual(p.artist, "The Persuader")
        XCTAssertEqual(p.title, "Östermalm")
        XCTAssertTrue(p.hasSeparator)
        XCTAssertFalse(p.separatorWasWeak)
    }

    func test_trackNumberPrefix_isStripped() {
        let p = FilenameParser.parse(stem: "03 - Aphex Twin - Xtal")
        XCTAssertEqual(p.trackNumber, 3)
        XCTAssertEqual(p.artist, "Aphex Twin")
        XCTAssertEqual(p.title, "Xtal")
    }

    func test_trackNumberWithDot() {
        let p = FilenameParser.parse(stem: "07. Burial - Archangel")
        XCTAssertEqual(p.trackNumber, 7)
        XCTAssertEqual(p.artist, "Burial")
        XCTAssertEqual(p.title, "Archangel")
    }

    func test_leadingDigitsInArtistName_survive() {
        let p = FilenameParser.parse(stem: "2 Unlimited - No Limit")
        XCTAssertNil(p.trackNumber)
        XCTAssertEqual(p.artist, "2 Unlimited")
        XCTAssertEqual(p.title, "No Limit")
    }

    func test_vinylPosition_isStripped() {
        let p = FilenameParser.parse(stem: "B2 - Kungsholmen")
        XCTAssertEqual(p.vinylPosition, "B2")
        XCTAssertEqual(p.title, "Kungsholmen")
    }

    func test_catalogNumberPrefix_isExtracted() {
        let p = FilenameParser.parse(stem: "SK032 - The Persuader - Vasastaden")
        XCTAssertEqual(p.catalogNumber, "SK032")
        XCTAssertEqual(p.artist, "The Persuader")
        XCTAssertEqual(p.title, "Vasastaden")
    }

    func test_allCapsArtistWithoutDigits_isNotMistakenForCatalogNumber() {
        let p = FilenameParser.parse(stem: "SBTRKT - Wildfire")
        XCTAssertEqual(p.catalogNumber, "")
        XCTAssertEqual(p.artist, "SBTRKT")
        XCTAssertEqual(p.title, "Wildfire")
    }

    // MARK: - Trenner-Varianten

    func test_enDashSeparator() {
        let p = FilenameParser.parse(stem: "Moderat – Bad Kingdom")
        XCTAssertEqual(p.artist, "Moderat")
        XCTAssertEqual(p.title, "Bad Kingdom")
    }

    func test_underscoreStyle() {
        let p = FilenameParser.parse(stem: "Four_Tet_-_Baby")
        XCTAssertEqual(p.artist, "Four Tet")
        XCTAssertEqual(p.title, "Baby")
    }

    func test_bareHyphen_isWeakSeparator() {
        let p = FilenameParser.parse(stem: "Pinch-Qawwali")
        XCTAssertTrue(p.hasSeparator)
        XCTAssertTrue(p.separatorWasWeak)
        XCTAssertEqual(p.artist, "Pinch")
        XCTAssertEqual(p.title, "Qawwali")
    }

    func test_hyphenatedNameWithProperSeparator_keepsHyphen() {
        let p = FilenameParser.parse(stem: "Jean-Michel Jarre - Oxygene 4")
        XCTAssertEqual(p.artist, "Jean-Michel Jarre")
        XCTAssertEqual(p.title, "Oxygene 4")
        XCTAssertFalse(p.separatorWasWeak)
    }

    func test_noSeparator_everythingIsTitle() {
        let p = FilenameParser.parse(stem: "untitled groove sketch")
        XCTAssertFalse(p.hasSeparator)
        XCTAssertEqual(p.artist, "")
        XCTAssertEqual(p.title, "untitled groove sketch")
        XCTAssertFalse(p.isComplete)
        XCTAssertTrue(p.isUsable)
    }

    // MARK: - Mix-Version und feat.

    func test_mixVersion_staysInTitleAndIsExtracted() {
        let p = FilenameParser.parse(stem: "Len Faki - Mekong Delta (Extended Mix)")
        XCTAssertEqual(p.artist, "Len Faki")
        XCTAssertEqual(p.title, "Mekong Delta (Extended Mix)")
        XCTAssertEqual(p.mixVersion, "Extended Mix")
    }

    func test_mixVersionOnLeftSide_resolvesOrder() {
        let p = FilenameParser.parse(stem: "Strings Of Life (Juan Atkins Remix) - Rhythim Is Rhythim")
        XCTAssertEqual(p.artist, "Rhythim Is Rhythim")
        XCTAssertEqual(p.title, "Strings Of Life (Juan Atkins Remix)")
        XCTAssertFalse(p.orderIsAmbiguous)
    }

    func test_plainPair_staysAmbiguous() {
        let p = FilenameParser.parse(stem: "Innervisions - Howling")
        XCTAssertTrue(p.orderIsAmbiguous)
    }

    func test_nonMixBracket_isNotAMixVersion() {
        let p = FilenameParser.parse(stem: "Floating Points - Kuiper (Part 1)")
        XCTAssertEqual(p.mixVersion, "")
        XCTAssertEqual(p.title, "Kuiper (Part 1)")
    }

    func test_featuring_isExtractedButKeptInTitle() {
        let p = FilenameParser.parse(stem: "Disclosure - Latch feat. Sam Smith")
        XCTAssertEqual(p.featuring, "Sam Smith")
        XCTAssertEqual(p.title, "Latch feat. Sam Smith")
    }

    // MARK: - Rip-Reste

    func test_sitePrefix_isRemoved() {
        let p = FilenameParser.parse(stem: "[www.example.com] Skream - Midnight Request Line")
        XCTAssertEqual(p.artist, "Skream")
        XCTAssertEqual(p.title, "Midnight Request Line")
    }

    func test_bitrateTag_isRemoved() {
        let p = FilenameParser.parse(stem: "Digital Mystikz - Anti War Dub [320kbps]")
        XCTAssertEqual(p.title, "Anti War Dub")
    }

    func test_sourceTag_isRemoved() {
        let p = FilenameParser.parse(stem: "Objekt - Cactus (WEB)")
        XCTAssertEqual(p.title, "Cactus")
    }

    func test_yearInBrackets_isExtracted() {
        let p = FilenameParser.parse(stem: "The Persuader - Stockholm (1999)")
        XCTAssertEqual(p.year, 1999)
        XCTAssertEqual(p.title, "Stockholm")
    }

    // MARK: - searchQuery

    func test_searchQuery_dropsMixBracket() {
        let p = FilenameParser.parse(stem: "Len Faki - Mekong Delta (Extended Mix)")
        XCTAssertEqual(p.searchQuery, "Len Faki Mekong Delta")
    }

    func test_searchQuery_withoutArtist_isTitleOnly() {
        let p = FilenameParser.parse(stem: "Mekong Delta")
        XCTAssertEqual(p.searchQuery, "Mekong Delta")
    }
}

final class TextSimilarityTests: XCTestCase {

    func test_normalize_foldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(TextSimilarity.normalize("Östermalm (Original Mix)!"), "ostermalm original mix")
    }

    func test_normalize_dropsLeadingThe() {
        XCTAssertEqual(TextSimilarity.normalize("The Persuader"), "persuader")
    }

    func test_identicalStrings_areOne() {
        XCTAssertEqual(TextSimilarity.similarity("Mekong Delta", "mekong delta"), 1.0, accuracy: 0.0001)
    }

    func test_reorderedTokens_scoreHigh() {
        XCTAssertGreaterThan(TextSimilarity.similarity("Delta Mekong", "Mekong Delta"), 0.9)
    }

    func test_typo_scoresHigh() {
        XCTAssertGreaterThan(TextSimilarity.similarity("Mekong Delata", "Mekong Delta"), 0.85)
    }

    func test_unrelatedStrings_scoreLow() {
        XCTAssertLessThan(TextSimilarity.similarity("Strings Of Life", "Anti War Dub"), 0.4)
    }

    func test_emptyAgainstNonEmpty_isZero() {
        XCTAssertEqual(TextSimilarity.similarity("", "Qawwali"), 0.0, accuracy: 0.0001)
    }
}
