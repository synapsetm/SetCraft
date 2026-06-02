import Foundation
import SetCraftCoreObjC

/// BPM-Analyse über aubio (Beat-Tracking). Wendet anschliessend die
/// Oktav-Korrektur des `BPMRangePreset` an, damit DnB-typische
/// halben/doppelten Schätzungen (z. B. 87 statt 174) in den erwarteten
/// Bereich projiziert werden.
public actor AubioBPMAnalyzer: BPMAnalyzer {

    public init() {}

    public func analyzeBPM(url: URL, expectedRange: BPMRangePreset) async throws -> Double {
        let pcm = try PCMLoader.load(url: url)
        let raw = SetifyAnalyzerBridge.analyzeBPM(
            fromFloat32Samples: pcm.samples,
            sampleRate: pcm.sampleRate
        )
        guard raw > 0 else {
            throw AnalysisError.analysisFailed(url, reason: "aubio lieferte keine BPM")
        }
        return expectedRange.corrected(raw)
    }
}
