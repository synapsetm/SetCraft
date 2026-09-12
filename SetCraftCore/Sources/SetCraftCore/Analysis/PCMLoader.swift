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

    /// Kopfdaten eines beginnenden Streams.
    public struct StreamFormat: Sendable {
        public let sampleRate: Double
        /// Aus Dateilänge bzw. Track-Dauer geschätzte Gesamtzahl Mono-Frames.
        /// `0`, wenn sie sich nicht ermitteln liess.
        public let estimatedFrameCount: Int
    }

    /// Dekodiert blockweise und reicht jeden Mono-Block sofort weiter, ohne
    /// die Datei im Speicher zu sammeln. Ein zweistündiger Mix kostet so ein
    /// paar Kilobyte statt ~1,3 GB.
    ///
    /// **`onStart` kann mehr als einmal kommen.** Scheitert der
    /// `AVAudioFile`-Pfad mitten im Stream, wird über `AVAssetReader` von
    /// vorne begonnen — der Aufrufer muss bei jedem `onStart` verwerfen, was
    /// er bisher gesammelt hat.
    public static func stream(
        url: URL,
        onStart: (StreamFormat) -> Void,
        onBlock: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
        do {
            try streamViaAVAudioFile(url: url, onStart: onStart, onBlock: onBlock)
        } catch {
            log.error("AVAudioFile path failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to AVAssetReader.")
            try streamViaAssetReader(url: url, primaryError: error, onStart: onStart, onBlock: onBlock)
        }
    }

    /// Sammelt den kompletten Stream in einem Stück — für aubio und
    /// libKeyFinder, die den ganzen Track am Stück brauchen.
    public static func load(url: URL) throws -> PCM {
        var monoData = Data()
        var sampleRate: Double = 0
        try stream(
            url: url,
            onStart: { format in
                // Decoder-Neustart: alles bisher Gesammelte ist ungültig.
                sampleRate = format.sampleRate
                monoData.removeAll(keepingCapacity: true)
                if format.estimatedFrameCount > 0 {
                    monoData.reserveCapacity(format.estimatedFrameCount * MemoryLayout<Float>.size)
                }
            },
            onBlock: { block in
                if let base = block.baseAddress {
                    appendFloats(&monoData, base: base, count: block.count)
                }
            }
        )
        guard !monoData.isEmpty else { throw AnalysisError.noSamples(url) }
        log.debug("Decoded \(url.lastPathComponent, privacy: .public): \(monoData.count / 4) mono samples @ \(sampleRate) Hz")
        return PCM(samples: monoData, sampleRate: sampleRate)
    }

    // MARK: - AVAudioFile-Pfad (Standard)

    private static func streamViaAVAudioFile(
        url: URL,
        onStart: (StreamFormat) -> Void,
        onBlock: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
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

        onStart(StreamFormat(sampleRate: sampleRate, estimatedFrameCount: Int(file.length)))

        var monoTemp = [Float](repeating: 0, count: Int(frameCapacity))
        let invChannels = 1.0 / Float(channelCount)
        var deliveredFrames = 0

        // Apple-Doku: `read(into:)` darf mitten im Stream auch weniger als
        // `frameCapacity` Frames liefern, ohne dass der Stream zu Ende ist —
        // `frameLength == 0` ist deshalb das eine Abbruch-Signal.
        //
        // In der Praxis gibt es ein zweites: viele Dateien **werfen** am Ende,
        // statt 0 Frames zu liefern (`nilError` aus dem ExtAudioFile-Pfad).
        // Wer das als Fehler behandelt, wirft die bereits komplett dekodierte
        // Datei weg und lässt den AVAssetReader-Fallback alles noch einmal
        // machen — also jede Analyse und jede Waveform doppelt. Haben wir
        // schon Frames geliefert, ist ein Wurf hier schlicht das Dateiende.
        while true {
            do {
                try file.read(into: buffer)
            } catch {
                if deliveredFrames > 0 { break }
                throw error
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
                    onBlock(UnsafeBufferPointer(start: src, count: framesRead))
                } else {
                    for f in 0..<framesRead {
                        var sum: Float = 0
                        for c in 0..<channelCount {
                            sum += src[f * channelCount + c]
                        }
                        monoTemp[f] = sum * invChannels
                    }
                    monoTemp.withUnsafeBufferPointer { ptr in
                        onBlock(UnsafeBufferPointer(rebasing: ptr[0..<framesRead]))
                    }
                }
            } else {
                // Non-interleaved: channels[c] zeigt auf den c-ten Kanal.
                if channelCount == 1 {
                    onBlock(UnsafeBufferPointer(start: channels[0], count: framesRead))
                } else {
                    for f in 0..<framesRead {
                        var sum: Float = 0
                        for c in 0..<channelCount {
                            sum += channels[c][f]
                        }
                        monoTemp[f] = sum * invChannels
                    }
                    monoTemp.withUnsafeBufferPointer { ptr in
                        onBlock(UnsafeBufferPointer(rebasing: ptr[0..<framesRead]))
                    }
                }
            }
            deliveredFrames += framesRead
        }

        guard deliveredFrames > 0 else {
            throw AnalysisError.noSamples(url)
        }
        log.debug("Streamed \(url.lastPathComponent, privacy: .public) via AVAudioFile: \(deliveredFrames) mono samples")
    }

    // MARK: - AVAssetReader-Pfad (Fallback)

    /// Decoder-Fallback über AVURLAsset + AVAssetReader. Greift, wenn
    /// AVAudioFile auf dieser Datei scheitert (typisch: bestimmte MP3-Header,
    /// die der ExtAudioFile-Pfad nicht verdaut). Liefert immer Float32 mono
    /// in der nativen Sample-Rate des Audio-Tracks.
    private static func streamViaAssetReader(
        url: URL,
        primaryError: Error,
        onStart: (StreamFormat) -> Void,
        onBlock: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
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

        let durationSeconds = CMTimeGetSeconds(track.timeRange.duration)
        let estimatedFrames = (durationSeconds.isFinite && durationSeconds > 0)
            ? Int(durationSeconds * sampleRate)
            : 0
        onStart(StreamFormat(sampleRate: sampleRate, estimatedFrameCount: estimatedFrames))

        var deliveredFrames = 0
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
                let frames = length / MemoryLayout<Float>.size
                if frames > 0 {
                    let floats = UnsafeRawPointer(p).assumingMemoryBound(to: Float.self)
                    onBlock(UnsafeBufferPointer(start: floats, count: frames))
                    deliveredFrames += frames
                }
            }
        }

        if reader.status == .failed {
            throw AnalysisError.decodeFailed(url, underlying: reader.error ?? primaryError)
        }
        guard deliveredFrames > 0 else {
            throw AnalysisError.noSamples(url)
        }
        log.debug("Streamed \(url.lastPathComponent, privacy: .public) via AVAssetReader: \(deliveredFrames) mono samples @ \(sampleRate) Hz")
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
