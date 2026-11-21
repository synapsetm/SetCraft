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
    /// Modifikationsdatum der Datei aus dem Dateisystem. Sortier- und
    /// Anzeige-Quelle in der Library. Wird vom `LibraryRepository` aus den
    /// FileManager-Attributen gesetzt; `nil` solange noch nichts gelesen wurde.
    public var modifiedDate: Date?
    /// Wie oft der Track in SetCraft abgespielt wurde. App-lokal in der DB
    /// gehalten — Tag-Daten der Datei bleiben unangetastet (Serato/Rekordbox
    /// haben kein Standardfeld dafür).
    public var playCount: Int
    /// Position in der Playlist (ab 1), wenn der Track aus einer Playlist-
    /// Quelle stammt; sonst `nil`. Reine Anzeige- und Sortierhilfe — wird
    /// weder in den Tag noch in den Cache geschrieben. Ein Track, der
    /// mehrfach in der Playlist steht, ist mehrfach mit eigener ID da.
    public var playlistIndex: Int?

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
        fileSize: Int64? = nil,
        modifiedDate: Date? = nil,
        playCount: Int = 0,
        playlistIndex: Int? = nil
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
        self.modifiedDate = modifiedDate
        self.playCount = playCount
        self.playlistIndex = playlistIndex
    }

    /// Ab dieser Länge behandeln wir eine Datei als DJ-Mix. Club-Tracks
    /// liegen bei 4–8 Minuten, Extended Mixes bei bis zu 12, Longform-/
    /// Live-Fassungen bei ~15 — DJ-Mixes, Podcasts und Radioshows fangen
    /// bei 30 Minuten an. 20 Minuten trennt das praktisch ohne Falsch-
    /// Positive.
    public static let djMixThresholdSeconds: TimeInterval = 20 * 60

    /// Heuristik allein aus der Dauer (kommt beim Scan gratis aus TagLibs
    /// `AudioProperties`, kostet also kein Dekodieren und wird nirgends
    /// persistiert).
    ///
    /// Für einen Mix sind BPM und Key sinnlos — er läuft über viele Tempi
    /// und Tonarten, herauskäme der Wert des ersten Abschnitts. Die Analyse
    /// kostet dafür Minuten und über ein Gigabyte Speicher, weil der
    /// `PCMLoader` die ganze Datei dekodiert im RAM hält. Der automatische
    /// Pfad überspringt solche Dateien deshalb; ein ausdrücklicher
    /// Re-Analyze läuft weiterhin durch.
    public var isLikelyDJMix: Bool {
        durationSeconds >= Self.djMixThresholdSeconds
    }

    public var displayTitle: String {
        title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }

    /// Dateiendung in Grossbuchstaben (z. B. "MP3", "FLAC"), leer falls keine.
    public var fileType: String {
        url.pathExtension.uppercased()
    }

    /// Inhalt dieses Tracks mit der Identität von `row` (ID und Playlist-
    /// Position). Für Playlists, in denen dieselbe Datei mehrfach steht: ein
    /// Edit an einer Zeile wird so auf die anderen gespiegelt, ohne dass sie
    /// ihre Tabellenidentität verlieren.
    public func reassigned(to row: Track) -> Track {
        Track(id: row.id, url: url, title: title, artist: artist, album: album,
              genre: genre, comment: comment, durationSeconds: durationSeconds,
              bpm: bpm, key: key, rating: rating, year: year, bitrate: bitrate,
              label: label, fileSize: fileSize, modifiedDate: modifiedDate,
              playCount: playCount, playlistIndex: row.playlistIndex)
    }

    /// Sortierschlüssel der Spalte «#»: Tracks ohne Playlist-Position ans Ende.
    public var playlistIndexSortable: Int {
        playlistIndex ?? Int.max
    }

    /// Dateiname inkl. Endung (z. B. "Artist - Title.mp3").
    public var fileName: String {
        url.lastPathComponent
    }
}
