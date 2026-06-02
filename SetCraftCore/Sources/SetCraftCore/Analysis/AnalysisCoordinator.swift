import Foundation
import OSLog
import SetCraftCoreObjC

/// Bündelt BPM- und Key-Analyse eines Tracks, damit die Datei nur einmal
/// dekodiert werden muss. Mehrere Anfragen werden vom Actor serialisiert —
/// das hält den Spitzenspeicherverbrauch konstant, auch wenn der Nutzer
/// eine ganze Bibliothek auf einmal anstösst.
public actor AnalysisCoordinator {

    private static let log = Logger(subsystem: "ch.beat.buehler.Setify", category: "Analysis")

    public struct Result: Sendable {
        public let bpm: Double?
        public let key: CamelotKey?

        public init(bpm: Double? = nil, key: CamelotKey? = nil) {
            self.bpm = bpm
            self.key = key
        }
    }

    public init() {}

    public func analyze(
        url: URL,
        needsBPM: Bool,
        needsKey: Bool,
        bpmRange: BPMRangePreset
    ) async throws -> Result {
        guard needsBPM || needsKey else { return Result() }

        Self.log.info("Analysing \(url.lastPathComponent, privacy: .public) (needsBPM=\(needsBPM), needsKey=\(needsKey))")

        let pcm = try PCMLoader.load(url: url)

        var bpm: Double? = nil
        if needsBPM {
            let raw = SetCraftAnalyzerBridge.analyzeBPM(
                fromFloat32Samples: pcm.samples,
                sampleRate: pcm.sampleRate
            )
            Self.log.info("aubio raw BPM for \(url.lastPathComponent, privacy: .public): \(raw)")
            if raw > 0 {
                bpm = bpmRange.corrected(raw)
            }
        }

        var key: CamelotKey? = nil
        if needsKey {
            let camelot = SetCraftAnalyzerBridge.analyzeKey(
                fromFloat32Samples: pcm.samples,
                sampleRate: pcm.sampleRate
            )
            Self.log.info("KeyFinder result for \(url.lastPathComponent, privacy: .public): \(camelot ?? "nil", privacy: .public)")
            if let camelot, let parsed = CamelotKey(camelot) {
                key = parsed
            }
        }

        return Result(bpm: bpm, key: key)
    }
}
