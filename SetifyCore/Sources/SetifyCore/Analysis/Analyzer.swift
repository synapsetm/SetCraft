import Foundation

public protocol Analyzer: Sendable {
    func analyzeBPM(url: URL) async throws -> Double
    func analyzeKey(url: URL) async throws -> CamelotKey
}
