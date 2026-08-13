import Foundation
import GRDB

/// Art einer Quelle: ein Ordner (flacher Scan, ohne Unterverzeichnisse) oder
/// eine einzelne Datei (genau ein Track). Einzeldateien entstehen, wenn ein Track
/// von aussen geöffnet wird (Finder-Doppelklick, Drag & Drop) und noch keine
/// Quelle ihn abdeckt — dann wird nur dieser Track aufgenommen, nicht sein
/// ganzes Verzeichnis.
public enum SourceKind: String, Codable, Sendable {
    case folder
    case file
}

/// Eine vom Nutzer ausgewählte Quelle. `bookmark_data` ist ein
/// Security-Scoped Bookmark, das beim nächsten Start aufgelöst wird, um
/// erneut Zugriff auf Ordner bzw. Datei zu bekommen.
public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "folders"

    public var id: String        // UUID-String
    public var url: String       // zuletzt aufgelöster Pfad (für Display)
    public var name: String      // Anzeige-Name (default: lastPathComponent)
    public var bookmark_data: Data
    public var added_at: Double
    public var kind: SourceKind

    public init(id: String = UUID().uuidString,
                url: URL,
                name: String,
                bookmarkData: Data,
                addedAt: Date = Date(),
                kind: SourceKind = .folder) {
        self.id = id
        self.url = url.standardizedFileURL.path
        self.name = name
        self.bookmark_data = bookmarkData
        self.added_at = addedAt.timeIntervalSince1970
        self.kind = kind
    }

    public var displayURL: URL { URL(fileURLWithPath: url) }
    public var addedAt: Date { Date(timeIntervalSince1970: added_at) }
}
