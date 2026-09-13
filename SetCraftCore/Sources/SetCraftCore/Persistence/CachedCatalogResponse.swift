import Foundation
import GRDB

/// Rohe Antwort einer Katalog-Abfrage (Discogs), wie sie vom Server kam.
///
/// Gespeichert wird absichtlich das unveränderte JSON und nicht das geparste
/// Ergebnis: ändert sich unser Scoring oder kommt ein Feld dazu, lässt sich
/// alles neu auswerten, ohne das Rate-Limit-Budget erneut zu verbrennen.
public struct CachedCatalogResponse: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "catalog_cache"

    /// Vollständige Request-URL als Schlüssel.
    public var key: String
    public var payload: Data
    public var cached_at: Double

    public init(key: String, payload: Data, cachedAt: Date = Date()) {
        self.key = key
        self.payload = payload
        self.cached_at = cachedAt.timeIntervalSince1970
    }
}
