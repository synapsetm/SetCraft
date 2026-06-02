import Foundation
import SetCraftCoreObjC

/// Key-Erkennung über libKeyFinder. Mappt das Ergebnis auf Camelot.
public actor KeyFinderAnalyzer: KeyAnalyzer {

    public init() {}

    public func analyzeKey(url: URL) async throws -> CamelotKey? {
        let pcm = try PCMLoader.load(url: url)
        let camelot = SetifyAnalyzerBridge.analyzeKey(
            fromFloat32Samples: pcm.samples,
            sampleRate: pcm.sampleRate
        )
        guard let camelot else { return nil }
        guard let key = CamelotKey(camelot) else {
            throw AnalysisError.analysisFailed(url, reason: "Unbekannte Camelot-Notation: \(camelot)")
        }
        return key
    }
}
