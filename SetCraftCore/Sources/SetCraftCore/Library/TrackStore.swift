import Foundation

/// Persistenter Speicher für Tracks. Implementierung in Phase 1: TagLib
/// schreibt direkt in die Dateimetadaten (siehe `TagLibTrackStore`). Eine
/// SQLite-Cache-Variante kommt erst in Phase 5.
public protocol TrackStore: Sendable {
    /// Schreibt den vollständigen Track-Zustand atomar zurück in die Datei.
    /// Schreibzugriffe auf denselben Store sind serialisiert.
    func save(_ track: Track) async throws

    /// Markiert eine Datei als „aktiv im Player". Schreibvorgänge auf diese
    /// URL werden abgelehnt, bis sie wieder freigegeben wird.
    func setActiveTrack(_ url: URL?) async
}
