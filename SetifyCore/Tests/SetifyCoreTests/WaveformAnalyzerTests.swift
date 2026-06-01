import XCTest
import AVFoundation
import Foundation
@testable import SetifyCore

final class WaveformAnalyzerTests: XCTestCase {

    func test_pureBass_dominatesRedChannel() throws {
        // 80 Hz-Sinus → muss klar in den Bass-Bins landen.
        let url = try writeSineWAV(frequency: 80, durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try WaveformAnalyzer.analyze(url: url)
        XCTAssertFalse(data.bins.isEmpty)

        let avgBass = data.bins.map(\.bass).reduce(0, +) / Float(data.bins.count)
        let avgMid  = data.bins.map(\.mid).reduce(0, +)  / Float(data.bins.count)
        let avgHigh = data.bins.map(\.high).reduce(0, +) / Float(data.bins.count)

        XCTAssertGreaterThan(avgBass, avgMid * 2,
            "Bass (\(avgBass)) sollte deutlich über Mid (\(avgMid)) liegen")
        XCTAssertGreaterThan(avgBass, avgHigh * 2,
            "Bass (\(avgBass)) sollte deutlich über High (\(avgHigh)) liegen")
    }

    func test_pureTreble_dominatesBlueChannel() throws {
        // 8 kHz → Höhen-Band.
        let url = try writeSineWAV(frequency: 8_000, durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try WaveformAnalyzer.analyze(url: url)
        let avgBass = data.bins.map(\.bass).reduce(0, +) / Float(data.bins.count)
        let avgHigh = data.bins.map(\.high).reduce(0, +) / Float(data.bins.count)
        XCTAssertGreaterThan(avgHigh, avgBass * 2,
            "High (\(avgHigh)) sollte deutlich über Bass (\(avgBass)) liegen")
    }

    func test_secondsPerBin_isAround12ms_at44100Hz() throws {
        let url = try writeSineWAV(frequency: 440, durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try WaveformAnalyzer.analyze(url: url)
        XCTAssertEqual(data.secondsPerBin, 512.0 / 44_100.0, accuracy: 1e-6)
    }

    // MARK: - Helper

    private func writeSineWAV(frequency: Double, durationSeconds: Double) throws -> URL {
        let sampleRate: Double = 44_100
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setify-wf-\(UUID().uuidString).wav")
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: sampleRate, channels: 1, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let ch = buf.floatChannelData![0]
        let omega = 2.0 * .pi * frequency / sampleRate
        for f in 0..<Int(frameCount) {
            ch[f] = Float(sin(omega * Double(f)) * 0.5)
        }
        try outFile.write(from: buf)
        return url
    }
}
