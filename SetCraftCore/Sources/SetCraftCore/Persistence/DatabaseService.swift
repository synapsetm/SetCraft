import Foundation
import GRDB
import OSLog

/// Verkapselt das SQLite-File hinter einer GRDB-`DatabaseQueue`. Die App
/// arbeitet ausschliesslich über typsichere Reader/Writer dieses Actors.
/// Datenbank-URL kommt von aussen, weil die App auf macOS in einer Sandbox
/// läuft und der Pfad via FileManager.applicationSupport gebaut wird.
public actor DatabaseService {

    private static let log = Logger(subsystem: "ch.beat.buehler.Setify", category: "Database")

    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
        Self.log.info("Database ready at \(databaseURL.path, privacy: .public)")
    }

    // MARK: - Migrationen

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "tracks") { t in
                t.column("url",  .text).primaryKey()
                t.column("title",  .text).notNull().defaults(to: "")
                t.column("artist", .text).notNull().defaults(to: "")
                t.column("album",  .text).notNull().defaults(to: "")
                t.column("genre",  .text).notNull().defaults(to: "")
                t.column("comment",.text).notNull().defaults(to: "")
                t.column("bpm",    .double)               // nullable
                t.column("camelot_key", .text)            // nullable, Format "8A"
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("duration_seconds", .double).notNull().defaults(to: 0)
                t.column("modified_at", .double).notNull().defaults(to: 0)
                t.column("cached_at",   .double).notNull().defaults(to: 0)
            }

            try db.create(table: "waveforms") { t in
                t.column("url", .text).primaryKey()
                t.column("sample_rate",     .double).notNull()
                t.column("seconds_per_bin", .double).notNull()
                t.column("modified_at",     .double).notNull()
                t.column("bin_count",       .integer).notNull()
                t.column("bins_data",       .blob).notNull()
            }

            try db.create(table: "folders") { t in
                t.column("id",  .text).primaryKey()
                t.column("url", .text).notNull()
                t.column("name", .text).notNull()
                t.column("bookmark_data", .blob).notNull()
                t.column("added_at", .double).notNull()
            }
        }
        m.registerMigration("v2_extra_track_columns") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "year",      .integer)
                t.add(column: "bitrate",   .integer)
                t.add(column: "label",     .text).notNull().defaults(to: "")
                t.add(column: "file_size", .integer)
            }
        }
        // v3: alte Cache-Zeilen haben year/bitrate/file_size = NULL, weil sie
        // vor der Erweiterung geschrieben wurden. Wir leeren die Tabelle, damit
        // beim nächsten Scan TagLib + FileManager die neuen Felder auffüllen.
        m.registerMigration("v3_refresh_cache_after_extra_columns") { db in
            try db.execute(sql: "DELETE FROM tracks")
        }
        return m
    }()

    // MARK: - Tracks

    public func loadTrack(url: URL) async throws -> CachedTrack? {
        try await dbQueue.read { db in
            try CachedTrack.fetchOne(db, key: url.standardizedFileURL.path)
        }
    }

    public func saveTrack(_ track: Track, modifiedAt: Date) async throws {
        let row = CachedTrack(track: track, modifiedAt: modifiedAt, cachedAt: Date())
        try await dbQueue.write { db in
            try row.save(db)
        }
    }

    public func deleteTrack(url: URL) async throws {
        _ = try await dbQueue.write { db in
            try CachedTrack.deleteOne(db, key: url.standardizedFileURL.path)
        }
    }

    // MARK: - Waveforms

    public func loadWaveform(url: URL, expectedModifiedAt: Date) async throws -> WaveformData? {
        let path = url.standardizedFileURL.path
        let stored = try await dbQueue.read { db in
            try CachedWaveform.fetchOne(db, key: path)
        }
        guard let stored else { return nil }
        // Stale-Check: Datei-Modifikationsdatum muss zum Cache passen.
        let storedTime: Double = stored.modified_at
        let expected:   Double = expectedModifiedAt.timeIntervalSince1970
        if abs(storedTime - expected) > 1.0 {
            return nil
        }
        return stored.waveformData()
    }

    public func saveWaveform(_ data: WaveformData, url: URL, modifiedAt: Date) async throws {
        let row = CachedWaveform(url: url.standardizedFileURL.path,
                                  data: data,
                                  modifiedAt: modifiedAt)
        try await dbQueue.write { db in
            try row.save(db)
        }
    }

    // MARK: - Folders

    public func listFolders() async throws -> [FolderRecord] {
        try await dbQueue.read { db in
            try FolderRecord.order(Column("added_at")).fetchAll(db)
        }
    }

    public func saveFolder(_ folder: FolderRecord) async throws {
        try await dbQueue.write { db in
            try folder.save(db)
        }
    }

    public func deleteFolder(id: String) async throws {
        _ = try await dbQueue.write { db in
            try FolderRecord.deleteOne(db, key: id)
        }
    }
}
