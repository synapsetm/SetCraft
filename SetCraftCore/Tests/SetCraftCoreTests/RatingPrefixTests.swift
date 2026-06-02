import XCTest
@testable import SetCraftCore

final class RatingPrefixTests: XCTestCase {

    // MARK: - parse

    func test_parse_nil_givesNoneAndEmpty() {
        let (rating, rest) = RatingPrefix.parse(nil)
        XCTAssertEqual(rating.stars, 0)
        XCTAssertEqual(rest, "")
    }

    func test_parse_empty_givesNoneAndEmpty() {
        let (rating, rest) = RatingPrefix.parse("")
        XCTAssertEqual(rating.stars, 0)
        XCTAssertEqual(rest, "")
    }

    func test_parse_plainComment_givesNoneAndOriginal() {
        let (rating, rest) = RatingPrefix.parse("schöner peak track")
        XCTAssertEqual(rating.stars, 0)
        XCTAssertEqual(rest, "schöner peak track")
    }

    func test_parse_fullPrefix_extractsRating() {
        let (rating, rest) = RatingPrefix.parse("★★★★☆ | groove")
        XCTAssertEqual(rating.stars, 4)
        XCTAssertEqual(rest, "groove")
    }

    func test_parse_fivePrefix_extractsAll() {
        let (rating, rest) = RatingPrefix.parse("★★★★★ | banger")
        XCTAssertEqual(rating.stars, 5)
        XCTAssertEqual(rest, "banger")
    }

    func test_parse_onePrefix_extractsOne() {
        let (rating, rest) = RatingPrefix.parse("★☆☆☆☆ | meh")
        XCTAssertEqual(rating.stars, 1)
        XCTAssertEqual(rest, "meh")
    }

    func test_parse_prefixOnly_emptyRest() {
        let (rating, rest) = RatingPrefix.parse("★★★☆☆")
        XCTAssertEqual(rating.stars, 3)
        XCTAssertEqual(rest, "")
    }

    func test_parse_prefixWithTrailingSpace_handlesGracefully() {
        // Falls jemand das Separator-Format leicht abweicht
        let (rating, rest) = RatingPrefix.parse("★★★★☆ groove")
        XCTAssertEqual(rating.stars, 4)
        XCTAssertEqual(rest, "groove")
    }

    func test_parse_invalidSymbolsInPrefixRegion_noPrefix() {
        // Wenn die ersten 5 Zeichen kein gültiges Sterne-Muster sind,
        // bleibt der Kommentar unverändert.
        let (rating, rest) = RatingPrefix.parse("★★X★☆ | bla")
        XCTAssertEqual(rating.stars, 0)
        XCTAssertEqual(rest, "★★X★☆ | bla")
    }

    func test_parse_lessThanFiveChars_noPrefix() {
        let (rating, rest) = RatingPrefix.parse("★★★")
        XCTAssertEqual(rating.stars, 0)
        XCTAssertEqual(rest, "★★★")
    }

    func test_parse_preservesUmlautsAndEmoji() {
        let (rating, rest) = RatingPrefix.parse("★★★☆☆ | für die Halle 🔥")
        XCTAssertEqual(rating.stars, 3)
        XCTAssertEqual(rest, "für die Halle 🔥")
    }

    // MARK: - format

    func test_format_zeroStars_returnsRestUnchanged() {
        XCTAssertEqual(RatingPrefix.format(.none, rest: "groove"), "groove")
        XCTAssertEqual(RatingPrefix.format(.none, rest: ""), "")
    }

    func test_format_threeStars_addsPrefix() {
        XCTAssertEqual(
            RatingPrefix.format(Rating(stars: 3), rest: "groove"),
            "★★★☆☆ | groove"
        )
    }

    func test_format_fiveStars_addsPrefix() {
        XCTAssertEqual(
            RatingPrefix.format(Rating(stars: 5), rest: "banger"),
            "★★★★★ | banger"
        )
    }

    func test_format_emptyRest_omitsSeparator() {
        XCTAssertEqual(
            RatingPrefix.format(Rating(stars: 4), rest: ""),
            "★★★★☆"
        )
    }

    // MARK: - round-trip

    func test_roundTrip_preservesRatingAndComment() {
        let cases: [(stars: Int, comment: String)] = [
            (0, "groove"),
            (3, "groove"),
            (5, "banger 🔥"),
            (1, "für die Halle"),
            (4, ""),
            (0, "")
        ]
        for (stars, comment) in cases {
            let rating = Rating(stars: stars)
            let written = RatingPrefix.format(rating, rest: comment)
            let (readRating, readRest) = RatingPrefix.parse(written)
            XCTAssertEqual(readRating.stars, stars, "stars für \(written)")
            XCTAssertEqual(readRest, comment, "rest für \(written)")
        }
    }
}
