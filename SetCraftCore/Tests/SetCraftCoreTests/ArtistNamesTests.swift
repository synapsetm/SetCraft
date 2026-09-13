import XCTest
@testable import SetCraftCore

final class ArtistNamesTests: XCTestCase {

    // MARK: - Zerlegen für Vergleiche

    func test_components_splitsOnCommaAndAmpersand() {
        XCTAssertEqual(ArtistNames.components(of: "Luca Antolini, Andrea Montorsi"),
                       ["Luca Antolini", "Andrea Montorsi"])
        XCTAssertEqual(ArtistNames.components(of: "Dense & Pika"), ["Dense", "Pika"])
        XCTAssertEqual(ArtistNames.components(of: "Oliver Heldens x Will Clarke"),
                       ["Oliver Heldens", "Will Clarke"])
    }

    func test_components_splitsOnRelationshipWords() {
        XCTAssertEqual(ArtistNames.components(of: "Disclosure feat. Sam Smith"),
                       ["Disclosure", "Sam Smith"])
        XCTAssertEqual(ArtistNames.components(of: "Sasha vs. John Digweed"),
                       ["Sasha", "John Digweed"])
    }

    func test_singleName_staysWhole() {
        XCTAssertEqual(ArtistNames.components(of: "Paul van Dyk"), ["Paul van Dyk"])
        XCTAssertFalse(ArtistNames.hasExplicitSeparator("Paul van Dyk"))
        XCTAssertTrue(ArtistNames.hasExplicitSeparator("Luca Antolini, Andrea Montorsi"))
    }

    // MARK: - Zerlegen anhand bekannter Namen

    private var library: [String: String] {
        ArtistNames.knownNames(from: [
            Track(url: URL(fileURLWithPath: "/m/a.mp3"), artist: "Luca Antolini"),
            Track(url: URL(fileURLWithPath: "/m/b.mp3"), artist: "Andrea Montorsi"),
            Track(url: URL(fileURLWithPath: "/m/c.mp3"), artist: "Oliver Heldens"),
            Track(url: URL(fileURLWithPath: "/m/d.mp3"), artist: "Will Clarke"),
            Track(url: URL(fileURLWithPath: "/m/e.mp3"), artist: "Paul van Dyk"),
            Track(url: URL(fileURLWithPath: "/m/f.mp3"), artist: "Paul")
        ])
    }

    func test_knownNames_takesEachNameFromAListedTag() {
        let known = ArtistNames.knownNames(from: [
            Track(url: URL(fileURLWithPath: "/m/a.mp3"), artist: "Dense & Pika")
        ])
        XCTAssertEqual(known[TextSimilarity.normalize("Dense")], "Dense")
        XCTAssertEqual(known[TextSimilarity.normalize("Pika")], "Pika")
    }

    func test_splitsConcatenatedArtists() {
        XCTAssertEqual(
            ArtistNames.split("Luca Antolini Andrea Montorsi", usingKnownNames: library),
            ["Luca Antolini", "Andrea Montorsi"]
        )
        XCTAssertEqual(
            ArtistNames.split("Oliver Heldens Will Clarke", usingKnownNames: library),
            ["Oliver Heldens", "Will Clarke"]
        )
    }

    func test_knownFullName_isNeverSplit() {
        // „Paul" ist für sich bekannt — „Paul van Dyk" bleibt trotzdem ganz.
        XCTAssertNil(ArtistNames.split("Paul van Dyk", usingKnownNames: library))
    }

    func test_unknownName_isNotSplit() {
        XCTAssertNil(ArtistNames.split("Some Unknown Duo", usingKnownNames: library))
    }

    func test_onlyOneNameKnown_stillSplits() {
        // Der Normalfall in einer frisch gescannten Bibliothek: „Luca Antolini"
        // steht schon da, „Mystery Guest" noch nicht.
        XCTAssertEqual(
            ArtistNames.split("Luca Antolini Mystery Guest", usingKnownNames: library),
            ["Luca Antolini", "Mystery Guest"]
        )
        // Auch andersherum, wenn der bekannte Name hinten steht.
        XCTAssertEqual(
            ArtistNames.split("Mystery Guest Will Clarke", usingKnownNames: library),
            ["Mystery Guest", "Will Clarke"]
        )
    }

    func test_singleWordRemainder_isNotSplitOff() {
        // „Skudge" allein wäre ein zu dünner zweiter Interpret.
        XCTAssertNil(ArtistNames.split("Luca Antolini Skudge", usingKnownNames: library))
    }

    func test_threeWordName_withKnownFirstWord_staysWhole() {
        // Selbst wenn „Paul" für sich bekannt ist: beide Teile müssten zwei
        // Wörter haben, „Paul" hat eines.
        let known = ArtistNames.knownNames(from: [
            Track(url: URL(fileURLWithPath: "/m/x.mp3"), artist: "Paul")
        ])
        XCTAssertNil(ArtistNames.split("Paul van Dyk", usingKnownNames: known))
    }

    func test_nothingKnown_isNeverSplit() {
        XCTAssertNil(ArtistNames.split("Some Unknown Other Duo", usingKnownNames: [:]))
    }

    func test_join_usesTheBeatportStyleSeparator() {
        XCTAssertEqual(ArtistNames.join(["Luca Antolini", "Andrea Montorsi"]),
                       "Luca Antolini, Andrea Montorsi")
    }
}
