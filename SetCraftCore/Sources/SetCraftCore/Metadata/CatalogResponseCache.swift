import Foundation

/// Persistenter Cache für Katalog-Antworten.
///
/// Nicht Bequemlichkeit, sondern Notwendigkeit: Discogs erlaubt 25 Anfragen pro
/// Minute ohne Token und 60 mit. Ein zweiter Lauf über denselben Ordner — nach
/// einem Abbruch, einem Neustart oder weil der Nutzer nochmal hinschaut — darf
/// dieses Budget nicht erneut verbrennen.
public protocol CatalogResponseCache: Sendable {
    /// Rohe Antwort, falls vorhanden und nicht älter als `maxAge`.
    func cachedResponse(forKey key: String, maxAge: TimeInterval) async -> Data?
    func store(_ data: Data, forKey key: String) async
}
