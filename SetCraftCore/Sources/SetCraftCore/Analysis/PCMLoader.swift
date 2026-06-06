import AVFoundation
import Foundation
import OSLog

/// Lädt eine Audiodatei und liefert Mono-Float32-Samples zurück (für die
/// aubio/KeyFinder-Bridge sowie die Waveform-Analyse).
///
/// Primärer Pfad ist `AVAudioFile` mit dem `processingFormat` der Datei
/// (typischerweise Float32 non-interleaved). Auf MP3s, bei denen der
/// ExtAudioFile-Decoder mit einem generischen ObjC-Fehler aussteigt — auch
/// wenn AVAudioPlayerNode dieselbe Datei problemlos abspielt — wird
/// automatisch auf einen `AVAssetReader`-Pfad zurückgefallen. Der nutzt
/// CoreMedia-Decoder und kommt mit den problematischen Headern durch.
public enum PCMLoader {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "PCMLoader")

    public struct PCM: Sendable {
        public let samples: Data   // float32 mono
        public let sampleRate: Double
    }

    public static func load(url: URL) throws -> PCM {
        do {
            return try loadViaAVAudioFile(url: url)
        } catch {
            log.error("AVAudioFile path failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to AVAssetReader.")
            return try loadViaAssetReader(url: url, primaryError: error)
        }
    }

    // MARK: - AVAudioFile-Pfad (Standard)

    private static func loadViaAVAudioFile(url: URL) throws -> PCM {
        let file = try AVAudioFile(forReading: url)

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

        // Apple-Doku: `read(into:)` darf mitten im Stream auch weniger als
        // `frameCapacity` Frames liefern, ohne dass der Stream zu Ende ist —
        // einzig sicheres Abbruch-Signal ist `frameLength == 0`.
        while true {
            try file.read(into: buffer)
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
        }

        guard !monoData.isEmpty else {
            throw AnalysisError.noSamples(url)
        }
        log.debug("Decoded \(url.lastPathComponent, privacy: .public) via AVAudioFile: \(monoData.count / 4) mono samples")

        return PCM(samples: monoData, sampleRate: sampleRate)
    }

    // MARK: - AVAssetReader-Pfad (Fallback)

    /// Decoder-Fallback über AVURLAsset + AVAssetReader. Greift, wenn
    /// AVAudioFile auf dieser Datei scheitert (typisch: bestimmte MP3-Header,
    /// die der ExtAudioFile-Pfad nicht verdaut). Liefert immer Float32 mono
    /// in der nativen Sample-Rate des Audio-Tracks.
    private static func loadViaAssetReader(url: URL, primaryError: Error) throws -> PCM {
        let asset = AVURLAsset(url: url)

        // tracks(withMediaType:) ist auf macOS 13+ als deprecated markiert,
        // aber synchron und funktional. Wir bleiben hier synchron, weil die
        // umliegende API (PCMLoader.load) ebenfalls synchron ist und in einem
        // Background-Task läuft. Der Aufruf ist günstig, wenn das Asset
        // bereits initialisiert wurde.
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw AnalysisError.decodeFailed(url, underlying: primaryError)
        }

        let sampleRate = nativeSampleRate(for: track) ?? 44_100

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AnalysisError.decodeFailed(url, underlying: error)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AnalysisError.decodeFailed(url, underlying: primaryError)
        }
        reader.add(output)

        guard reader.startReading() else {
            throw AnalysisError.decodeFailed(url, underlying: reader.error ?? primaryError)
        }

        var monoData = Data()
        // Reservierung anhand der Track-Dauer — vermeidet ständiges Reallozieren.
        let durationSeconds = CMTimeGetSeconds(track.timeRange.duration)
        if durationSeconds.isFinite, durationSeconds > 0 {
            monoData.reserveCapacity(Int(durationSeconds * sampleRate) * MemoryLayout<Float>.size)
        }

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length: Int = 0
            var ptr: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &ptr
            )
            if status == kCMBlockBufferNoErr, let p = ptr, length > 0 {
                monoData.append(
                    UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self),
                    count: length
                )
            }
        }

        if reader.status == .failed {
            throw AnalysisError.decodeFailed(url, underlying: reader.error ?? primaryError)
        }
        guard !monoData.isEmpty else {
            throw AnalysisError.noSamples(url)
        }
        log.debug("Decoded \(url.lastPathComponent, privacy: .public) via AVAssetReader: \(monoData.count / 4) mono samples @ \(sampleRate) Hz")

        return PCM(samples: monoData, sampleRate: sampleRate)
    }

    private static func nativeSampleRate(for track: AVAssetTrack) -> Double? {
        guard let descCF = track.formatDescriptions.first else { return nil }
        let desc = descCF as! CMAudioFormatDescription
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        let rate = asbdPtr.pointee.mSampleRate
        return rate > 0 ? rate : nil
    }

    // MARK: - Helpers

    private static func appendFloats(_ data: inout Data, base: UnsafePointer<Float>, count: Int) {
        data.append(
            UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
            count: count * MemoryLayout<Float>.size
        )
    }
}
