import XCTest
@testable import SetifyCore

final class CamelotKeyTests: XCTestCase {

    // MARK: - tonicChromatic

    func test_tonicChromatic_minorAnchors() {
        // 5A = Cm  → 0
        XCTAssertEqual(CamelotKey(number: 5, mode: .minor)!.tonicChromatic, 0)
        // 6A = Gm  → 7
        XCTAssertEqual(CamelotKey(number: 6, mode: .minor)!.tonicChromatic, 7)
        // 8A = Am  → 9
        XCTAssertEqual(CamelotKey(number: 8, mode: .minor)!.tonicChromatic, 9)
        // 1A = G#m → 8
        XCTAssertEqual(CamelotKey(number: 1, mode: .minor)!.tonicChromatic, 8)
        // 12A = C#m → 1
        XCTAssertEqual(CamelotKey(number: 12, mode: .minor)!.tonicChromatic, 1)
    }

    func test_tonicChromatic_majorAnchors() {
        // 8B = C   → 0
        XCTAssertEqual(CamelotKey(number: 8, mode: .major)!.tonicChromatic, 0)
        // 9B = G   → 7
        XCTAssertEqual(CamelotKey(number: 9, mode: .major)!.tonicChromatic, 7)
        // 11B = A  → 9
        XCTAssertEqual(CamelotKey(number: 11, mode: .major)!.tonicChromatic, 9)
        // 1B = B   → 11
        XCTAssertEqual(CamelotKey(number: 1, mode: .major)!.tonicChromatic, 11)
    }

    // MARK: - semitoneShift

    func test_semitoneShift_sameKey_isZero() {
        let k = CamelotKey(number: 8, mode: .minor)!
        XCTAssertEqual(k.semitoneShift(to: k), 0)
    }

    func test_semitoneShift_minorPositive() {
        // 5A (Cm) → 8A (Am) = +9 → in −5…+6 verschoben: −3
        let from = CamelotKey(number: 5, mode: .minor)!
        let to   = CamelotKey(number: 8, mode: .minor)!
        XCTAssertEqual(from.semitoneShift(to: to), -3)
    }

    func test_semitoneShift_majorShortPath() {
        // 8B (C) → 9B (G) = +7 → −5
        let from = CamelotKey(number: 8, mode: .major)!
        let to   = CamelotKey(number: 9, mode: .major)!
        XCTAssertEqual(from.semitoneShift(to: to), -5)
    }

    func test_semitoneShift_camelotNeighbor_isFifth() {
        // Echte 5er-Quint: 8A → 7A = D-Moll. Cm → Dm = +2 Halbtöne, oder Am → Dm = -7 → +5
        let from = CamelotKey(number: 8, mode: .minor)! // Am
        let to   = CamelotKey(number: 7, mode: .minor)! // Dm
        // Am(9) → Dm(2): (2 - 9 + 12) mod 12 = 5 → ≤6 also +5
        XCTAssertEqual(from.semitoneShift(to: to), 5)
    }

    func test_semitoneShift_modeMismatch_isNil() {
        let minor = CamelotKey(number: 8, mode: .minor)!
        let major = CamelotKey(number: 8, mode: .major)!
        XCTAssertNil(minor.semitoneShift(to: major))
        XCTAssertNil(major.semitoneShift(to: minor))
    }

    // MARK: - nudged

    func test_nudged_zero_returnsSelf() {
        let k = CamelotKey(number: 8, mode: .minor)!
        XCTAssertEqual(k.nudged(bySemitones: 0), k)
    }

    func test_nudged_preservesMode() {
        let minor = CamelotKey(number: 5, mode: .minor)!
        XCTAssertEqual(minor.nudged(bySemitones: 5).mode, .minor)
        let major = CamelotKey(number: 8, mode: .major)!
        XCTAssertEqual(major.nudged(bySemitones: -3).mode, .major)
    }

    func test_nudged_plusSeven_landsOnCamelotNeighbor() {
        // Cm (5A) + 7 Halbtöne = Gm (6A)
        let cm = CamelotKey(number: 5, mode: .minor)!
        XCTAssertEqual(cm.nudged(bySemitones: 7), CamelotKey(number: 6, mode: .minor)!)
        // C (8B) + 7 = G (9B)
        let c = CamelotKey(number: 8, mode: .major)!
        XCTAssertEqual(c.nudged(bySemitones: 7), CamelotKey(number: 9, mode: .major)!)
    }

    func test_nudged_minusTwelve_isIdentity() {
        let k = CamelotKey(number: 3, mode: .minor)!
        XCTAssertEqual(k.nudged(bySemitones: -12), k)
    }

    func test_nudged_roundTrip_acrossAllKeysAndShifts() {
        for mode in [CamelotKey.Mode.major, .minor] {
            for n in 1...12 {
                let k = CamelotKey(number: n, mode: mode)!
                for shift in -12...12 {
                    let target = k.nudged(bySemitones: shift)
                    XCTAssertEqual(target.mode, mode,
                        "Mode wechselt bei \(k) +\(shift)")
                    // Round-Trip: zurück muss wieder k geben.
                    XCTAssertEqual(target.nudged(bySemitones: -shift), k,
                        "Round-Trip kaputt bei \(k) +\(shift)")
                }
            }
        }
    }

    func test_semitoneShift_consistentWithNudged() {
        // shift(a → b) = s  ⇒  a.nudged(s) == b   (für gleichen Mode)
        for mode in [CamelotKey.Mode.major, .minor] {
            for a in 1...12 {
                for b in 1...12 {
                    let from = CamelotKey(number: a, mode: mode)!
                    let to   = CamelotKey(number: b, mode: mode)!
                    guard let s = from.semitoneShift(to: to) else {
                        XCTFail("semitoneShift soll bei gleichem Mode nie nil sein")
                        continue
                    }
                    XCTAssertEqual(from.nudged(bySemitones: s), to,
                        "shift+nudge inkonsistent für \(from) → \(to)")
                }
            }
        }
    }
}
