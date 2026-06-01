import Foundation
import GRDB

/// Eine vom Nutzer ausgewählte Quelle (Ordner). `bookmark_data` ist ein
/// Security-Scoped Bookmark, das beim nächsten Start aufgelöst wird, um
/// erneut Zugriff auf den Ordner zu bekommen.
public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "folders"

    public var id: String        // UUID-String
    public var url: String       // zuletzt aufgelöster Pfad (für Display)
    public var name: String      // Anzeige-Name (default: lastPathComponent)
    public var bookmark_data: Data
    public var added_at: Double

    public init(id: String = UUID().uuidString,
                url: URL,
                name: String,
                bookmarkData: Data,
                addedAt: Date = Date()) {
        self.id = id
        self.url = url.standardizedFileURL.path
        self.name = name
        self.bookmark_data = bookmarkData
        self.added_at = addedAt.timeIntervalSince1970
    }

    public var displayURL: URL { URL(fileURLWithPath: url) }
    public var addedAt: Date { Date(timeIntervalSince1970: added_at) }
}
