import XCTest
@testable import SetCraftCore

/// Hält die 20-Minuten-Grenze fest, an der der automatische Pfad eine Datei
/// als DJ-Mix behandelt und BPM/Key/Welle nicht mehr selbst berechnet.
final class TrackHeuristicsTests: XCTestCase {

    private func track(minutes: Double) -> Track {
        Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), durationSeconds: minutes * 60)
    }

    func test_clubTrack_isNotAMix() {
        XCTAssertFalse(track(minutes: 6).isLikelyDJMix)
    }

    func test_longformTrack_justBelowThreshold_isNotAMix() {
        XCTAssertFalse(track(minutes: 19.9).isLikelyDJMix)
    }

    func test_exactlyAtThreshold_isAMix() {
        XCTAssertTrue(track(minutes: 20).isLikelyDJMix)
    }

    func test_twoHourSet_isAMix() {
        XCTAssertTrue(track(minutes: 120).isLikelyDJMix)
    }

    func test_unknownDuration_isNotAMix() {
        // TagLib konnte die Länge nicht lesen → lieber analysieren als
        // stillschweigend überspringen.
        XCTAssertFalse(track(minutes: 0).isLikelyDJMix)
    }
}
