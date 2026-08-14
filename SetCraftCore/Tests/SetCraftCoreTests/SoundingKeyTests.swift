import XCTest
@testable import SetCraftCore

final class SoundingKeyTests: XCTestCase {

    private func track(bpm: Double?, key: String?) -> Track {
        var t = Track(url: URL(fileURLWithPath: "/tmp/x.mp3"))
        t.bpm = bpm
        t.key = key.flatMap { CamelotKey($0) }
        return t
    }

    // MARK: - PitchMath

    func test_semitoneShift_unityRate_isZero() {
        XCTAssertEqual(PitchMath.semitoneShift(forRate: 1.0), 0, accuracy: 1e-9)
    }

    func test_semitoneShift_doubleRate_isTwelveSemitones() {
        XCTAssertEqual(PitchMath.semitoneShift(forRate: 2.0), 12, accuracy: 1e-9)
    }

    func test_semitoneShift_sixPercent_isAboutOneSemitone() {
        // Faustregel aus SPEC §5b: ~6 % ≈ 1 Halbton.
        XCTAssertEqual(PitchMath.semitoneShift(forRate: 1.06), 1.0, accuracy: 0.02)
    }

    func test_cents_isHundredTimesSemitones() {
        let rate = 1.15
        XCTAssertEqual(PitchMath.cents(forRate: rate),
                       PitchMath.semitoneShift(forRate: rate) * 100,
                       accuracy: 1e-9)
    }

    func test_rateForSemitones_roundTrips() {
        for n in [-5.0, -1.0, 0.0, 1.0, 3.0, 7.0] {
            let r = PitchMath.rate(forSemitones: n)
            XCTAssertEqual(PitchMath.semitoneShift(forRate: r), n, accuracy: 1e-9)
        }
    }

    func test_semitoneShift_zeroOrNegativeRate_isZero() {
        XCTAssertEqual(PitchMath.semitoneShift(forRate: 0), 0)
        XCTAssertEqual(PitchMath.cents(forRate: -1), 0)
    }

    // MARK: - SoundingKey

    func test_soundingKey_unityRate_isUnshifted() {
        let sk = SoundingKey(original: CamelotKey("8A")!, rate: 1.0)
        XCTAssertEqual(sk.semitones, 0)
        XCTAssertEqual(sk.sounding, CamelotKey("8A")!)
        XCTAssertFalse(sk.isShifted)
        XCTAssertFalse(sk.isAmbiguous)
    }

    func test_soundingKey_oneSemitoneUp_movesSevenCamelotSteps() {
        // Ein Halbton = 7 Camelot-Schritte im Quintenzirkel: 8A → 3A.
        let sk = SoundingKey(original: CamelotKey("8A")!,
                             rate: PitchMath.rate(forSemitones: 1))
        XCTAssertEqual(sk.semitones, 1)
        XCTAssertEqual(sk.sounding, CamelotKey("3A")!)
        XCTAssertTrue(sk.isShifted)
    }

    func test_soundingKey_preservesMode() {
        let major = SoundingKey(original: CamelotKey("8B")!,
                                rate: PitchMath.rate(forSemitones: 2))
        XCTAssertEqual(major.sounding.mode, .major)
    }

    func test_soundingKey_ambiguous_whenExactlyBetweenTwoKeys() {
        // Eine halbe Stufe zwischen zwei Halbtönen → Rundung willkürlich.
        let sk = SoundingKey(original: CamelotKey("8A")!,
                             rate: PitchMath.rate(forSemitones: 1.5))
        XCTAssertTrue(sk.isAmbiguous)
    }

    func test_soundingKey_notAmbiguous_justInsideThreshold() {
        let sk = SoundingKey(original: CamelotKey("8A")!,
                             rate: PitchMath.rate(forSemitones: 1.39))
        XCTAssertFalse(sk.isAmbiguous)
    }

    func test_soundingKey_ambiguous_justOutsideThreshold() {
        let sk = SoundingKey(original: CamelotKey("8A")!,
                             rate: PitchMath.rate(forSemitones: 1.41))
        XCTAssertTrue(sk.isAmbiguous)
    }

    // MARK: - Track-Integration

    func test_playingRate_isMasterOverOriginal() {
        let t = track(bpm: 140, key: "8A")
        XCTAssertEqual(t.playingRate(masterBPM: 175)!, 1.25, accuracy: 1e-9)
    }

    func test_playingRate_nilWithoutMasterOrBPM() {
        XCTAssertNil(track(bpm: 140, key: "8A").playingRate(masterBPM: nil))
        XCTAssertNil(track(bpm: nil, key: "8A").playingRate(masterBPM: 175))
        XCTAssertNil(track(bpm: 0, key: "8A").playingRate(masterBPM: 175))
    }

    func test_playingBPM_followsMaster() {
        let t = track(bpm: 140, key: "8A")
        XCTAssertEqual(t.playingBPM(masterBPM: 175)!, 175, accuracy: 1e-9)
    }

    func test_playingBPM_fallsBackToOriginal_withoutMaster() {
        let t = track(bpm: 140, key: "8A")
        XCTAssertEqual(t.playingBPM(masterBPM: nil)!, 140, accuracy: 1e-9)
    }

    func test_playingKey_nilWithoutMasterBPM() {
        let t = track(bpm: 140, key: "8A")
        XCTAssertNil(t.playingKey(masterBPM: nil))
    }

    func test_playingKey_nilWithoutAnalyzedKey() {
        let t = track(bpm: 140, key: nil)
        XCTAssertNil(t.playingKey(masterBPM: 175))
    }

    func test_playingKey_shiftsWithMasterTempo() {
        // 140 → 148.4 BPM entspricht ziemlich genau einem Halbton.
        let t = track(bpm: 140, key: "8A")
        let sk = t.playingKey(masterBPM: 140 * PitchMath.rate(forSemitones: 1))
        XCTAssertEqual(sk?.semitones, 1)
        XCTAssertEqual(sk?.sounding, CamelotKey("3A")!)
    }

    // MARK: - Sortierung

    func test_keySortValue_usesSoundingKeyWithMasterTempo() {
        let t = track(bpm: 140, key: "8A")
        let master = 140 * PitchMath.rate(forSemitones: 1)   // → 3A
        let shifted = t.keySortValue(masterBPM: master)
        let original = t.keySortValue(masterBPM: nil)
        XCTAssertEqual(shifted, CamelotKey("3A")!.number * 2)
        XCTAssertEqual(original, CamelotKey("8A")!.number * 2)
        XCTAssertNotEqual(shifted, original)
    }

    /// Die Sortierung muss der Anzeige folgen: was als klingender Key in der
    /// Zeile steht, ist auch der Sortierwert.
    func test_keySortValue_matchesDisplayedSoundingKey() {
        let master = 148.0
        for bpm in [128.0, 135.7, 140.0, 143.9, 151.3] {
            let t = track(bpm: bpm, key: "8A")
            let displayed = t.playingKey(masterBPM: master)!.sounding
            XCTAssertEqual(t.keySortValue(masterBPM: master),
                           displayed.number * 2 + (displayed.mode == .major ? 1 : 0),
                           "Sortierwert weicht bei \(bpm) BPM von der Anzeige ab")
        }
    }

    func test_keySortValue_groupsByCamelotNumber() {
        let a = track(bpm: 140, key: "3A")
        let b = track(bpm: 140, key: "3B")
        let c = track(bpm: 140, key: "4A")
        let sortA = a.keySortValue(masterBPM: nil)
        let sortB = b.keySortValue(masterBPM: nil)
        let sortC = c.keySortValue(masterBPM: nil)
        XCTAssertLessThan(sortA, sortB)   // 3A vor 3B
        XCTAssertLessThan(sortB, sortC)   // 3B vor 4A
    }

    func test_keySortValue_tracksWithoutKeySortLast() {
        let none = track(bpm: 140, key: nil)
        let some = track(bpm: 140, key: "12B")
        XCTAssertGreaterThan(none.keySortValue(masterBPM: nil),
                             some.keySortValue(masterBPM: nil))
    }

    // MARK: - Persistenz-Schutz (CLAUDE.md-Pflichtregel)

    func test_playingValues_doNotMutateStoredFields() {
        let t = track(bpm: 140, key: "8A")
        _ = t.playingBPM(masterBPM: 175)
        _ = t.playingKey(masterBPM: 175)
        _ = t.keySortValue(masterBPM: 175)
        // Die persistierten Felder sind unangetastet — nur sie gehen je in
        // einen Tag-Write.
        XCTAssertEqual(t.bpm, 140)
        XCTAssertEqual(t.key, CamelotKey("8A")!)
    }
}
