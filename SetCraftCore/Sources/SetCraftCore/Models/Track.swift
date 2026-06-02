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
    /// Erscheinungsjahr aus Tag (z. B. ID3 TYER), `nil` falls unbekannt.
    public var year: Int?
    /// Bitrate in kbps aus AudioProperties, `nil` falls unbekannt.
    public var bitrate: Int?
    /// Label / Publisher (TPUB / "LABEL" Frame), leer falls unbekannt.
    public var label: String
    /// Dateigrösse in Bytes, zur Scan-Zeit ermittelt. `nil` falls FileManager fehlschlug.
    public var fileSize: Int64?

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
        rating: Rating = .none,
        year: Int? = nil,
        bitrate: Int? = nil,
        label: String = "",
        fileSize: Int64? = nil
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
        self.year = year
        self.bitrate = bitrate
        self.label = label
        self.fileSize = fileSize
    }

    public var displayTitle: String {
        title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }

    /// Dateiendung in Grossbuchstaben (z. B. "MP3", "FLAC"), leer falls keine.
    public var fileType: String {
        url.pathExtension.uppercased()
    }
}
