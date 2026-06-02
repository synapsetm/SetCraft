import Foundation

public protocol BPMAnalyzer: Sendable {
    func analyzeBPM(url: URL, expectedRange: BPMRangePreset) async throws -> Double
}

public protocol KeyAnalyzer: Sendable {
    /// Liefert eine Camelot-Tonart oder `nil`, wenn das Stück als Silence
    /// klassifiziert oder die Analyse fehlgeschlagen ist.
    func analyzeKey(url: URL) async throws -> CamelotKey?
}

public enum AnalysisError: LocalizedError, Sendable {
    case decodeFailed(URL, underlying: Error?)
    case noSamples(URL)
    case analysisFailed(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let url, let underlying):
            return "Could not decode \(url.lastPathComponent): \(underlying?.localizedDescription ?? "-")"
        case .noSamples(let url):
            return "No samples found in \(url.lastPathComponent)."
        case .analysisFailed(let url, let reason):
            return "Analysis failed for \(url.lastPathComponent): \(reason)"
        }
    }
}
