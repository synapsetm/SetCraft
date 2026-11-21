import Foundation
import GRDB

/// Gespeicherter Relink eines Playlist-Eintrags: Originalzeile aus der M3U
/// → Datei, auf die er aufgelöst wurde. Die M3U selbst bleibt unverändert
/// (Spec §4); diese Tabelle ist die einzige Stelle, an der ein Relink lebt.
///
/// Schlüssel ist die Originalzeile, nicht die Position: ein Track, der
/// mehrfach in der Playlist steht, braucht den Relink nur einmal.
public struct PlaylistLink: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "playlist_links"

    public var playlist_id: String
    public var original_line: String
    public var resolved_path: String
    public var linked_at: Double

    public init(playlistID: String, originalLine: String, resolvedURL: URL, linkedAt: Date = Date()) {
        self.playlist_id = playlistID
        self.original_line = originalLine
        self.resolved_path = resolvedURL.standardizedFileURL.path
        self.linked_at = linkedAt.timeIntervalSince1970
    }
}
