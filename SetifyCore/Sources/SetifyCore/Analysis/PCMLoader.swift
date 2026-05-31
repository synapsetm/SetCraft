import AVFoundation
import Foundation

/// Lädt eine Audiodatei und liefert Mono-Float32-Samples zurück (für die
/// aubio/KeyFinder-Bridge). Lange Dateien werden in Blöcken gelesen und
/// laufend ins Ergebnis-`Data` gehängt.
public enum PCMLoader {

    public struct PCM: Sendable {
        public let samples: Data   // float32 mono
        public let sampleRate: Double
    }

    public static func load(url: URL) throws -> PCM {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AnalysisError.decodeFailed(url, underlying: error)
        }

        let inFormat = file.processingFormat
        let sampleRate = inFormat.sampleRate
        guard sampleRate > 0, inFormat.channelCount > 0 else {
            throw AnalysisError.noSamples(url)
        }

        // Float32-Interleaved, Sample-Rate und Kanalanzahl wie in der Datei
        // — wir mischen selbst auf Mono.
        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: inFormat.channelCount,
            interleaved: true
        ) else {
            throw AnalysisError.decodeFailed(url, underlying: nil)
        }

        let frameCapacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frameCapacity) else {
            throw AnalysisError.decodeFailed(url, underlying: nil)
        }

        var monoData = Data()
        monoData.reserveCapacity(Int(file.length) * MemoryLayout<Float>.size)
        let channelCount = Int(readFormat.channelCount)

        while true {
            try file.read(into: buffer)
            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }

            guard let floatData = buffer.floatChannelData else { break }
            // Bei `interleaved: true` zeigt floatChannelData[0] auf den
            // gesamten interleaved Buffer.
            let interleaved = floatData[0]

            if channelCount == 1 {
                monoData.append(
                    UnsafeRawPointer(interleaved).assumingMemoryBound(to: UInt8.self),
                    count: framesRead * MemoryLayout<Float>.size
                )
            } else {
                var mono = [Float](repeating: 0, count: framesRead)
                let inv = 1.0 / Float(channelCount)
                for f in 0..<framesRead {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += interleaved[f * channelCount + c]
                    }
                    mono[f] = sum * inv
                }
                mono.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        monoData.append(
                            UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                            count: framesRead * MemoryLayout<Float>.size
                        )
                    }
                }
            }

            if framesRead < Int(frameCapacity) { break }
            buffer.frameLength = 0
        }

        guard !monoData.isEmpty else {
            throw AnalysisError.noSamples(url)
        }

        return PCM(samples: monoData, sampleRate: sampleRate)
    }
}
