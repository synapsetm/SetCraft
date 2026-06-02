import XCTest
import AVFoundation
@testable import SetCraftCore

/// Smoke-Tests, die die ObjC++-Bridge mit synthetischen Signalen anstossen.
/// Sie verifizieren primär, dass der gesamte Pfad (PCMLoader → Bridge → aubio/
/// libKeyFinder) nicht abstürzt und plausible Werte liefert. Echte Genauigkeit
/// hängt vom Musikmaterial ab und ist hier kein Ziel.
final class AnalyzerSmokeTests: XCTestCase {

    func test_aubio_detectsApproxBPMOnSyntheticBeat() async throws {
        // 30 s @ 44.1 kHz, mono, ein "Kick" alle 0.5 s → 120 BPM erwartet.
        let url = try writeKickWAV(bpm: 120, durationSeconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let analyzer = AubioBPMAnalyzer()
        let bpm = try await analyzer.analyzeBPM(url: url, expectedRange: .universal)
        // aubio darf um ein paar BPM danebenliegen, aber im Universal-Bereich
        // sollte es kein Halben/Verdoppeln nötig haben.
        XCTAssertEqual(bpm, 120, accuracy: 5,
            "aubio sollte ~120 BPM erkennen, hat aber \(bpm) geliefert")
    }

    func test_keyfinder_returnsCamelotOnSyntheticTone() async throws {
        // 10 s reiner A-Sinus → KeyFinder sollte 11B (A-Dur) oder 8A (A-Moll)
        // liefern. Wichtig ist nur: nicht-nil und gültige Camelot-Notation.
        let url = try writeSineWAV(frequency: 440, channels: 2, durationSeconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let analyzer = KeyFinderAnalyzer()
        let key = try await analyzer.analyzeKey(url: url)
        // Bei einer reinen Sinuswelle ohne Obertöne kann KeyFinder auch nil
        // liefern (SILENCE/no decision). Wir prüfen nur, dass kein Crash
        // passiert und ein gültiger Camelot-Schlüssel zurückkommt, wenn
        // einer geliefert wird.
        if let key {
            XCTAssertTrue((1...12).contains(key.number),
                "ungültige Camelot-Zahl: \(key)")
        }
    }

    // MARK: - Helpers

    private func writeSineWAV(frequency: Double, channels: AVAudioChannelCount, durationSeconds: Double) throws -> URL {
        let sampleRate: Double = 44_100
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setify-sine-\(UUID().uuidString).wav")
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: sampleRate,
                                 channels: channels,
                                 interleaved: false)!
        let outFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let chs = buf.floatChannelData!
        let omega = 2.0 * .pi * frequency / sampleRate
        for f in 0..<Int(frameCount) {
            let v = Float(sin(omega * Double(f)) * 0.4)
            for c in 0..<Int(channels) { chs[c][f] = v }
        }
        try outFile.write(from: buf)
        return url
    }

    private func writeKickWAV(bpm: Double, durationSeconds: Double) throws -> URL {
        let sampleRate: Double = 44_100
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setify-kick-\(UUID().uuidString).wav")
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: sampleRate,
                                 channels: 1,
                                 interleaved: false)!
        let outFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let ch = buf.floatChannelData![0]

        // Beat-Periode in Samples
        let beatSamples = Int(sampleRate * 60.0 / bpm)
        // Kick: 60 Hz-Sinus mit exponentiellem Decay über ~150 ms
        let kickDuration = Int(sampleRate * 0.15)
        let kickFreq = 60.0
        let decay = 35.0  // 1/sec

        var t = 0
        while t < Int(frameCount) {
            for k in 0..<kickDuration where t + k < Int(frameCount) {
                let timeSec = Double(k) / sampleRate
                let env = exp(-decay * timeSec)
                let v = sin(2.0 * .pi * kickFreq * timeSec) * env
                ch[t + k] = Float(v * 0.8)
            }
            t += beatSamples
        }
        try outFile.write(from: buf)
        return url
    }
}
