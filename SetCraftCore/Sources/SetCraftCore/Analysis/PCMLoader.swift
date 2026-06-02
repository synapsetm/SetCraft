import AVFoundation
import Foundation
import OSLog

/// Lädt eine Audiodatei und liefert Mono-Float32-Samples zurück (für die
/// aubio/KeyFinder-Bridge). Liest mit dem `processingFormat` der Datei
/// (typischerweise Float32 non-interleaved) und mischt anschliessend auf
/// Mono. Lange Dateien werden in Blöcken verarbeitet, das Ergebnis ist
/// trotzdem ein zusammenhängendes `Data`.
public enum PCMLoader {

    private static let log = Logger(subsystem: "ch.beat.buehler.Setify", category: "PCMLoader")

    public struct PCM: Sendable {
        public let samples: Data   // float32 mono
        public let sampleRate: Double
    }

    public static func load(url: URL) throws -> PCM {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            log.error("AVAudioFile open failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw AnalysisError.decodeFailed(url, underlying: error)
        }

        // Wichtig: der Buffer muss `processingFormat` sein, sonst wirft
        // AVAudioFile.read(into:). Wir akzeptieren, was die Datei liefert.
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
            throw AnalysisError.noSamples(url)
        }
        log.debug("Opened \(url.lastPathComponent, privacy: .public): \(sampleRate) Hz, \(channelCount)ch, interleaved=\(format.isInterleaved), commonFormat=\(format.commonFormat.rawValue)")

        let frameCapacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw AnalysisError.decodeFailed(url, underlying: nil)
        }

        var monoData = Data()
        monoData.reserveCapacity(Int(file.length) * MemoryLayout<Float>.size)
        var monoTemp = [Float](repeating: 0, count: Int(frameCapacity))
        let invChannels = 1.0 / Float(channelCount)

        while true {
            do {
                try file.read(into: buffer)
            } catch {
                log.error("AVAudioFile.read failed: \(error.localizedDescription, privacy: .public)")
                throw AnalysisError.decodeFailed(url, underlying: error)
            }
            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }

            // Nur Float32-Buffer werden unterstützt — `processingFormat`
            // ist auf Apple-Plattformen praktisch immer Float32, aber wir
            // prüfen es, statt zu raten.
            guard format.commonFormat == .pcmFormatFloat32,
                  let channels = buffer.floatChannelData
            else {
                throw AnalysisError.decodeFailed(url, underlying: nil)
            }

            if format.isInterleaved {
                let src = channels[0]
                if channelCount == 1 {
                    appendFloats(&monoData, base: src, count: framesRead)
                } else {
                    for f in 0..<framesRead {
                        var sum: Float = 0
                        for c in 0..<channelCount {
                            sum += src[f * channelCount + c]
                        }
                        monoTemp[f] = sum * invChannels
                    }
                    monoTemp.withUnsafeBufferPointer { ptr in
                        if let base = ptr.baseAddress {
                            appendFloats(&monoData, base: base, count: framesRead)
                        }
                    }
                }
            } else {
                // Non-interleaved: channels[c] zeigt auf den c-ten Kanal.
                if channelCount == 1 {
                    appendFloats(&monoData, base: channels[0], count: framesRead)
                } else {
                    for f in 0..<framesRead {
                        var sum: Float = 0
                        for c in 0..<channelCount {
                            sum += channels[c][f]
                        }
                        monoTemp[f] = sum * invChannels
                    }
                    monoTemp.withUnsafeBufferPointer { ptr in
                        if let base = ptr.baseAddress {
                            appendFloats(&monoData, base: base, count: framesRead)
                        }
                    }
                }
            }

            if framesRead < Int(frameCapacity) { break }
        }

        guard !monoData.isEmpty else {
            throw AnalysisError.noSamples(url)
        }
        log.debug("Decoded \(url.lastPathComponent, privacy: .public): \(monoData.count / 4) mono samples")

        return PCM(samples: monoData, sampleRate: sampleRate)
    }

    private static func appendFloats(_ data: inout Data, base: UnsafePointer<Float>, count: Int) {
        data.append(
            UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
            count: count * MemoryLayout<Float>.size
        )
    }
}
