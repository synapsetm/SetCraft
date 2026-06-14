import Foundation
import GRDB

/// SQLite-Repräsentation eines Tracks. `url` ist der Primary Key
/// (standardisierter Pfad als String).
public struct CachedTrack: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "tracks"

    public var url: String
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var comment: String
    public var bpm: Double?
    public var camelot_key: String?
    public var rating: Int
    public var duration_seconds: Double
    public var modified_at: Double
    public var cached_at: Double
    public var year: Int?
    public var bitrate: Int?
    public var label: String
    public var file_size: Int64?
    public var play_count: Int

    public init(track: Track, modifiedAt: Date, cachedAt: Date) {
        self.url               = track.url.standardizedFileURL.path
        self.title             = track.title
        self.artist            = track.artist
        self.album             = track.album
        self.genre             = track.genre
        self.comment           = track.comment
        self.bpm               = track.bpm
        self.camelot_key       = track.key?.description
        self.rating            = track.rating.stars
        self.duration_seconds  = track.durationSeconds
        self.modified_at       = modifiedAt.timeIntervalSince1970
        self.cached_at         = cachedAt.timeIntervalSince1970
        self.year              = track.year
        self.bitrate           = track.bitrate
        self.label             = track.label
        self.file_size         = track.fileSize
        self.play_count        = track.playCount
    }

    /// Baut wieder ein domain-`Track` aus der Cache-Zeile. Die `id` wird
    /// neu vergeben — die Identität in der UI hängt am `URL`, nicht an
    /// einer persistierten UUID.
    public func track() -> Track {
        Track(
            url: URL(fileURLWithPath: url),
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            comment: comment,
            durationSeconds: duration_seconds,
            bpm: bpm,
            key: camelot_key.flatMap(CamelotKey.init),
            rating: Rating(stars: rating),
            year: year,
            bitrate: bitrate,
            label: label,
            fileSize: file_size,
            modifiedDate: Date(timeIntervalSince1970: modified_at),
            playCount: play_count
        )
    }

    public var modifiedAt: Date { Date(timeIntervalSince1970: modified_at) }
}
