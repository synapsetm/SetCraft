import XCTest
import AVFoundation
import Foundation
@testable import SetCraftCore

/// Deckt die blockweise Analyse ab: dass sie unterwegs Zwischenstände
/// liefert und am Ende exakt dasselbe herauskommt wie bei der Berechnung
/// am Stück.
final class WaveformStreamingTests: XCTestCase {

    func test_streamedResult_matchesWholeBufferResult() throws {
        let url = try writeSweepWAV(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try WaveformAnalyzer.analyze(url: url)
        let atOnce = WaveformAnalyzer.analyze(pcm: try PCMLoader.load(url: url))

        XCTAssertEqual(streamed.bins.count, atOnce.bins.count)
        XCTAssertEqual(streamed.secondsPerBin, atOnce.secondsPerBin, accuracy: 1e-9)
        for (i, pair) in zip(streamed.bins, atOnce.bins).enumerated() {
            XCTAssertEqual(pair.0.rms,  pair.1.rms,  accuracy: 1e-5, "rms bei Bin \(i)")
            XCTAssertEqual(pair.0.bass, pair.1.bass, accuracy: 1e-5, "bass bei Bin \(i)")
            XCTAssertEqual(pair.0.mid,  pair.1.mid,  accuracy: 1e-5, "mid bei Bin \(i)")
            XCTAssertEqual(pair.0.high, pair.1.high, accuracy: 1e-5, "high bei Bin \(i)")
        }
    }

    func test_partialUpdates_growMonotonicallyAndStayWithinEstimate() throws {
        let url = try writeSweepWAV(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        var partials: [WaveformData] = []
        let final = try WaveformAnalyzer.analyze(url: url, partialInterval: 0) { partials.append($0) }

        XCTAssertFalse(partials.isEmpty, "ohne Drosselung muss jeder Block einen Stand liefern")
        var previous = 0
        for partial in partials {
            XCTAssertGreaterThanOrEqual(partial.bins.count, previous, "Zwischenstände dürfen nicht schrumpfen")
            previous = partial.bins.count
            // Die Schätzung ist die Zeitachse, auf die die Views zeichnen —
            // sie darf nie kleiner sein als das, was schon da ist.
            XCTAssertGreaterThanOrEqual(partial.expectedBinCount, partial.bins.count)
        }
        // Der erste Stand muss ein echter Zwischenstand sein: nur ein Teil der
        // Welle, als unfertig markiert. (Der letzte deckt sich naturgemäss mit
        // dem Endergebnis — er entsteht aus dem letzten Block.)
        let first = try XCTUnwrap(partials.first)
        XCTAssertFalse(first.isComplete)
        XCTAssertLessThan(first.bins.count, final.bins.count)
        XCTAssertTrue(final.isComplete)
    }

    func test_finalResult_isComplete() throws {
        let url = try writeSweepWAV(durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let final = try WaveformAnalyzer.analyze(url: url)
        XCTAssertTrue(final.isComplete)
        XCTAssertEqual(final.expectedBinCount, final.bins.count)
        XCTAssertEqual(final.completion, 1, accuracy: 1e-9)
    }

    func test_partialEstimate_isCloseToFinalCount() throws {
        // Die geschätzte Bin-Zahl stammt aus der Dateilänge. Bei einer WAV
        // ist sie exakt; die View-Zeitachse darf darauf bauen.
        let url = try writeSweepWAV(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        var firstPartial: WaveformData?
        let final = try WaveformAnalyzer.analyze(url: url, partialInterval: 0) { partial in
            if firstPartial == nil { firstPartial = partial }
        }
        let estimate = try XCTUnwrap(firstPartial).expectedBinCount
        XCTAssertEqual(Double(estimate), Double(final.bins.count), accuracy: 2)
    }

    func test_incompleteData_usesEstimateForTimeAxis() {
        // Reine Modell-Logik: halb fertige Welle, Zeitachse bleibt die volle.
        let bins = Array(repeating: WaveformBin(rms: 1, bass: 1, mid: 0, high: 0), count: 50)
        let data = WaveformData(bins: bins, sampleRate: 44_100, secondsPerBin: 0.01, expectedBinCount: 200)
        XCTAssertFalse(data.isComplete)
        XCTAssertEqual(data.completion, 0.25, accuracy: 1e-9)
        XCTAssertEqual(data.totalSeconds, 2.0, accuracy: 1e-9)
    }

    // MARK: - Helper

    /// Frequenz-Sweep statt konstantem Sinus: so unterscheiden sich die Bins
    /// über die Zeit und ein Fehler beim Blockübergang fällt auf.
    private func writeSweepWAV(durationSeconds: Double) throws -> URL {
        let sampleRate: Double = 44_100
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setcraft-sweep-\(UUID().uuidString).wav")
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let ch = buf.floatChannelData![0]
        var phase = 0.0
        for f in 0..<Int(frameCount) {
            let progress = Double(f) / Double(frameCount)
            let freq = 60.0 + progress * 9_000.0
            phase += 2.0 * .pi * freq / sampleRate
            // Amplitude mitlaufen lassen, damit auch das RMS variiert.
            ch[f] = Float(sin(phase) * (0.2 + 0.6 * progress))
        }
        try outFile.write(from: buf)
        return url
    }
}
