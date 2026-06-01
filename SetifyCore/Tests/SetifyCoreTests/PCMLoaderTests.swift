import XCTest
import AVFoundation
@testable import SetifyCore

final class PCMLoaderTests: XCTestCase {

    /// Schreibt eine 2-Sekunden-Stereo-WAV-Datei mit einem 440 Hz-Sinus und
    /// liest sie via PCMLoader wieder ein. Verifiziert, dass das
    /// Stereo→Mono-Mischen den erwarteten Frame-Count produziert (das war
    /// der konkrete Phase-3-Bug: der Loader hat zuvor einen Interleaved-
    /// Buffer für AVAudioFile.read benutzt, was bei Stereo geworfen hat).
    func test_pcmLoader_readsStereoWAV() throws {
        let url = try writeSineWAV(channels: 2, sampleRate: 44100, durationSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let pcm = try PCMLoader.load(url: url)
        XCTAssertEqual(pcm.sampleRate, 44100)
        let frameCount = pcm.samples.count / MemoryLayout<Float>.size
        XCTAssertEqual(frameCount, 88_200, "2 s @ 44.1 kHz mono")
    }

    func test_pcmLoader_readsMonoWAV() throws {
        let url = try writeSineWAV(channels: 1, sampleRate: 44100, durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let pcm = try PCMLoader.load(url: url)
        XCTAssertEqual(pcm.sampleRate, 44100)
        let frameCount = pcm.samples.count / MemoryLayout<Float>.size
        XCTAssertEqual(frameCount, 44_100, "1 s @ 44.1 kHz mono")
    }

    // MARK: - Helper

    /// Schreibt eine WAV-Datei mit konstantem 440 Hz-Sinus, Float32-PCM.
    private func writeSineWAV(channels: AVAudioChannelCount, sampleRate: Double, durationSeconds: Double) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setify-test-\(UUID().uuidString).wav")

        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw NSError(domain: "PCMLoaderTests", code: 1)
        }

        let outFile = try AVAudioFile(forWriting: url, settings: writeFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "PCMLoaderTests", code: 2)
        }
        buffer.frameLength = frameCount

        if let chData = buffer.floatChannelData {
            let omega = 2.0 * Double.pi * 440.0 / sampleRate
            for f in 0..<Int(frameCount) {
                let v = Float(sin(omega * Double(f)) * 0.5)
                for c in 0..<Int(channels) {
                    chData[c][f] = v
                }
            }
        }

        try outFile.write(from: buffer)
        return url
    }
}
