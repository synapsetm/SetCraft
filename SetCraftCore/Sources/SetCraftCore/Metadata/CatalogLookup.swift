import Foundation

/// Anfrage an einen externen Musikkatalog.
public struct CatalogQuery: Sendable, Equatable {
    public var artist: String
    /// Titel **ohne** Mix-Klammer — die steht separat in `mixVersion`.
    public var title: String
    public var mixVersion: String
    public var catalogNumber: String
    public var year: Int?
    /// Spieldauer der Datei, zum Gegenprüfen des Treffers.
    public var durationSeconds: TimeInterval

    public init(
        artist: String,
        title: String,
        mixVersion: String = "",
        catalogNumber: String = "",
        year: Int? = nil,
        durationSeconds: TimeInterval = 0
    ) {
        self.artist = artist
        self.title = title
        self.mixVersion = mixVersion
        self.catalogNumber = catalogNumber
        self.year = year
        self.durationSeconds = durationSeconds
    }

    /// Ohne Titel hat eine Katalogsuche keine Chance.
    public var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Ein Treffer aus dem Katalog, auf die Felder reduziert, die SetCraft schreibt.
public struct CatalogMatch: Sendable, Equatable {
    public var artist: String
    /// Titel inklusive Mix-Klammer, schreibfertig.
    public var title: String
    public var mixVersion: String
    public var album: String
    public var label: String
    public var catalogNumber: String
    public var year: Int?
    /// Dauer laut Katalog — bei Discogs oft leer, darum optional.
    public var durationSeconds: TimeInterval?
    /// 0…1, vom Provider berechnet: wie gut passt der Treffer zur Anfrage.
    public var score: Double
    /// Provenienz, z. B. `discogs:release/1#B2`.
    public var reference: String

    public init(
        artist: String = "",
        title: String = "",
        mixVersion: String = "",
        album: String = "",
        label: String = "",
        catalogNumber: String = "",
        year: Int? = nil,
        durationSeconds: TimeInterval? = nil,
        score: Double = 0,
        reference: String = ""
    ) {
        self.artist = artist
        self.title = title
        self.mixVersion = mixVersion
        self.album = album
        self.label = label
        self.catalogNumber = catalogNumber
        self.year = year
        self.durationSeconds = durationSeconds
        self.score = score
        self.reference = reference
    }
}

/// Quelle für Katalog-Treffer. Hinter diesem Protokoll steckt in der App der
/// `DiscogsResolver`; in Tests eine Fake-Implementierung, damit die
/// Vorschlags-Kette ohne Netz prüfbar bleibt.
public protocol CatalogLookup: Sendable {
    /// Beste Treffer zuerst. Leeres Array = kein Treffer (kein Fehler).
    func search(_ query: CatalogQuery) async throws -> [CatalogMatch]
}

/// Wann der Katalog überhaupt gefragt wird.
public enum CatalogCheckPolicy: String, Sendable, CaseIterable, Codable {
    /// Nur offline arbeiten.
    case off
    /// Default: nur, wenn die Offline-Stufen unsicher oder unvollständig sind.
    /// Das ist der sparsame Modus — zwei Requests pro Track gehen bei 25–60
    /// Anfragen pro Minute sonst schnell ins Geld.
    case whenUncertain
    /// Jeden Track gegenprüfen, auch die sicheren. Teuer, aber die gründlichste
    /// Qualitätskontrolle.
    case always
}
