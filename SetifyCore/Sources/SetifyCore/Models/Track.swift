import Foundation

public struct Track: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    /// Bereinigter Kommentar ohne Sterne-Präfix. Wird beim Schreiben mit dem
    /// aktuellen Rating zusammengesetzt, damit der Nutzer-Text erhalten bleibt.
    public var comment: String
    public var durationSeconds: TimeInterval
    public var bpm: Double?
    public var key: CamelotKey?
    public var rating: Rating

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String = "",
        artist: String = "",
        album: String = "",
        genre: String = "",
        comment: String = "",
        durationSeconds: TimeInterval = 0,
        bpm: Double? = nil,
        key: CamelotKey? = nil,
        rating: Rating = .none
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.comment = comment
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.key = key
        self.rating = rating
    }

    public var displayTitle: String {
        title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }
}
