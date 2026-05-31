import Foundation

public protocol TrackStore: Sendable {
    func loadLibrary(folder: URL) async throws -> [Track]
    func updateRating(_ track: Track, stars: Int) async throws
    func updateBPM(_ track: Track, bpm: Double) async throws
    func updateKey(_ track: Track, key: CamelotKey) async throws
    func updateText(_ track: Track, field: EditableField, value: String) async throws
}
