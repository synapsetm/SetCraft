import Foundation
import GRDB
import OSLog

/// Verkapselt das SQLite-File hinter einer GRDB-`DatabaseQueue`. Die App
/// arbeitet ausschliesslich über typsichere Reader/Writer dieses Actors.
/// Datenbank-URL kommt von aussen, weil die App auf macOS in einer Sandbox
/// läuft und der Pfad via FileManager.applicationSupport gebaut wird.
public actor DatabaseService {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "Database")

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
        m.registerMigration("v4_track_play_count") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "play_count", .integer).notNull().defaults(to: 0)
            }
        }
        // v5: Quellen können jetzt auch einzelne Dateien sein (von aussen
        // geöffnete Tracks). Bestehende Zeilen sind allesamt Ordner.
        m.registerMigration("v5_folder_kind") { db in
            try db.alter(table: "folders") { t in
                t.add(column: "kind", .text).notNull().defaults(to: SourceKind.folder.rawValue)
            }
        }
        // v6: Cache fuer Katalog-Antworten (Discogs). Eigene Tabelle, weil die
        // Lebensdauer eine andere ist als die der Track-Zeilen: Katalogdaten
        // haengen nicht am mtime einer Datei, sondern altern nach Zeit.
        m.registerMigration("v6_catalog_cache") { db in
            try db.create(table: "catalog_cache") { t in
                t.column("key", .text).primaryKey()
                t.column("payload", .blob).notNull()
                t.column("cached_at", .double).notNull()
            }
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
        let key = track.url.standardizedFileURL.path
        let cachedAt = Date()
        try await dbQueue.write { db in
            var row = CachedTrack(track: track, modifiedAt: modifiedAt, cachedAt: cachedAt)
            // play_count ist app-lokal und überlebt Tag-/Scan-Updates. Wenn
            // bereits eine Zeile existiert, deren Wert behalten — sonst
            // würde jede Tag-Edit oder jeder Cache-Refresh den Counter
            // resetten.
            if let existing = try CachedTrack.fetchOne(db, key: key) {
                row.play_count = existing.play_count
            }
            try row.save(db)
        }
    }

    public func deleteTrack(url: URL) async throws {
        _ = try await dbQueue.write { db in
            try CachedTrack.deleteOne(db, key: url.standardizedFileURL.path)
        }
    }

    /// Erhöht den Play-Count für `url` um 1 und liefert den neuen Wert.
    /// Wenn die Zeile (noch) nicht im Cache liegt, liefert 0 zurück und
    /// macht nichts — der Counter zieht beim nächsten Scan auf.
    @discardableResult
    public func incrementPlayCount(url: URL) async throws -> Int {
        let path = url.standardizedFileURL.path
        return try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tracks SET play_count = play_count + 1 WHERE url = ?",
                arguments: [path]
            )
            return try CachedTrack.fetchOne(db, key: path)?.play_count ?? 0
        }
    }

    /// Setzt den Play-Count aller Tracks unterhalb `folder` auf 0.
    /// Vergleicht über das Pfad-Präfix, damit auch Unterordner-Tracks
    /// erfasst werden.
    public func resetPlayCounts(inFolder folder: URL) async throws {
        let prefix = folder.standardizedFileURL.path + "/"
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tracks SET play_count = 0 WHERE url LIKE ?",
                arguments: ["\(prefix)%"]
            )
        }
    }

    /// Alle Zeilen, die als **Zwilling** taugen: Artist und Titel gesetzt, Dauer
    /// bekannt. Quelle für den ordnerübergreifenden Duplikat-Abgleich der
    /// Tag-Ergänzung — der praktisch wichtigste Fall ist, dass die sauber
    /// getaggte Kopie in einem *anderen* Ordner liegt als die rohe.
    ///
    /// Gefiltert wird in SQL, damit bei grossen Bibliotheken nicht zehntausende
    /// nutzlose Zeilen durch den Decoder gehen.
    public func taggedTracks() async throws -> [Track] {
        try await dbQueue.read { db in
            try CachedTrack
                .filter(sql: "artist <> '' AND title <> '' AND duration_seconds > 0")
                .fetchAll(db)
                .map { $0.track() }
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
    // MARK: - Katalog-Cache

    public func loadCatalogResponse(key: String, maxAge: TimeInterval) async throws -> Data? {
        let row = try await dbQueue.read { db in
            try CachedCatalogResponse.fetchOne(db, key: key)
        }
        guard let row else { return nil }
        guard Date().timeIntervalSince1970 - row.cached_at <= maxAge else { return nil }
        return row.payload
    }

    public func saveCatalogResponse(_ data: Data, key: String) async throws {
        let row = CachedCatalogResponse(key: key, payload: data)
        try await dbQueue.write { db in
            try row.save(db)
        }
    }

    /// Raeumt abgelaufene Antworten weg. Wird beim Start angestossen, damit die
    /// Datei nicht unbegrenzt waechst.
    public func pruneCatalogCache(olderThan maxAge: TimeInterval) async throws {
        let cutoff = Date().timeIntervalSince1970 - maxAge
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM catalog_cache WHERE cached_at < ?", arguments: [cutoff])
        }
    }
}

/// Der DB-Actor ist der Katalog-Cache. Fehler werden hier geschluckt: ein
/// kaputter Cache darf eine Katalog-Abfrage nicht verhindern, er kostet dann
/// nur einen Request.
extension DatabaseService: CatalogResponseCache {

    public func cachedResponse(forKey key: String, maxAge: TimeInterval) async -> Data? {
        try? await loadCatalogResponse(key: key, maxAge: maxAge)
    }

    public func store(_ data: Data, forKey key: String) async {
        try? await saveCatalogResponse(data, key: key)
    }
}
