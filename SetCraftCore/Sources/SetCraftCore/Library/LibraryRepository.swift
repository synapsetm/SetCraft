import Foundation
import OSLog

/// Orchestriert das Lesen und Schreiben von Tracks: prüft zuerst den
/// SQLite-Cache, fällt bei `stale`-Werten (Datei-Modifikationsdatum
/// passt nicht mehr) auf TagLib zurück. Schreibvorgänge gehen weiterhin
/// durch `TagLibTrackStore` (Datei = Quelle der Wahrheit) und
/// aktualisieren anschliessend den Cache.
public actor LibraryRepository: TrackStore {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "LibraryRepository")

    private let database: DatabaseService
    private let tagStore: TagLibTrackStore

    public init(database: DatabaseService, tagStore: TagLibTrackStore = TagLibTrackStore()) {
        self.database = database
        self.tagStore = tagStore
    }

    // MARK: - Lesen

    /// Liest einen Track aus DB-Cache oder Datei. Bei stale Cache wird die
    /// Datei via TagLib (neu) gelesen und das Resultat re-cached.
    public func loadTrack(url: URL) async -> Track? {
        let mtime = (try? fileModifiedDate(url: url)) ?? Date()
        if let cached = try? await database.loadTrack(url: url),
           abs(cached.modified_at - mtime.timeIntervalSince1970) < 1.0 {
            return cached.track()
        }
        do {
            var fresh = try TagReader.read(url: url)
            fresh.modifiedDate = mtime
            try? await database.saveTrack(fresh, modifiedAt: mtime)
            // play_count im DB-Cache wurde von saveTrack erhalten; falls eine
            // alte Zeile existierte, deren Wert auch ins In-Memory-Track ziehen.
            if let row = try? await database.loadTrack(url: url) {
                fresh.playCount = row.play_count
            }
            return fresh
        } catch {
            Self.log.error("loadTrack failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Streamt alle Audio-Dateien im Ordner. Für jede URL wird der Cache
    /// konsultiert; das spart bei einem reinen App-Restart praktisch die
    /// gesamte TagLib-Leselast. Liefert zusätzlich ein `ScanReport` zurück,
    /// damit die UI bei leerem Ergebnis diagnostisch antworten kann
    /// (typisch: iCloud-Ordner mit noch-nicht-runtergeladenen Dateien).
    public nonisolated func scan(folder: URL) -> (stream: AsyncStream<Track>, report: ScanReport) {
        let (urls, report) = FolderScanner.collect(in: folder)
        let stream = AsyncStream<Track> { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                for url in urls {
                    if Task.isCancelled { break }
                    let track = await self.loadTrack(url: url) ?? Track(url: url)
                    continuation.yield(track)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, report)
    }

    // MARK: - TrackStore

    public func save(_ track: Track) async throws {
        try await save(track, force: false)
    }

    /// `force == true` umgeht den Active-Track-Guard im TagLibTrackStore.
    /// Wird vom iOS-Player für explizite User-Edits (TagEditSheet, Rating)
    /// genutzt — ohne diesen Bypass landeten Edits am gerade gespielten
    /// Track in einer Queue, die bis zum nächsten Track-Wechsel wartet.
    public func save(_ track: Track, force: Bool) async throws {
        try await tagStore.save(track, force: force)
        // Datei wurde neu geschrieben → mtime neu ermitteln.
        let mtime = (try? fileModifiedDate(url: track.url)) ?? Date()
        try? await database.saveTrack(track, modifiedAt: mtime)
    }

    public func setActiveTrack(_ url: URL?) async {
        await tagStore.setActiveTrack(url)
    }

    // MARK: - Löschen

    /// Ergebnis eines Löschlaufs. `trashUnavailable` ist kein Fehler, sondern
    /// eine Rückfrage: auf dem Volume gibt es keinen Papierkorb (typisch für
    /// SMB-/NAS-Mounts), der Aufrufer muss „endgültig löschen?" bestätigen
    /// lassen und dann `deletePermanently(_:)` rufen.
    public struct DeletionReport: Sendable {
        public struct Failure: Sendable {
            public let track: Track
            public let message: String
        }

        public var removed: [Track] = []
        public var trashUnavailable: [Track] = []
        public var failures: [Failure] = []
        /// Warum der Papierkorb nicht ging — für den Rückfrage-Dialog.
        public var trashFailureReason: String?

        public init() {}
    }

    /// Verschiebt die Dateien in den Papierkorb und räumt ihre Cache-Zeilen
    /// weg. Läuft auf demselben Actor wie `save(_:)`, kann sich also nicht mit
    /// einem laufenden Tag-Write derselben Datei überschneiden.
    public func moveToTrash(_ tracks: [Track]) async -> DeletionReport {
        var report = DeletionReport()
        let fm = FileManager.default

        for track in tracks {
            guard fm.fileExists(atPath: track.url.path) else {
                // Extern schon gelöscht — nur noch die Cache-Zeile aufräumen.
                try? await database.deleteTrack(url: track.url)
                report.removed.append(track)
                continue
            }
            do {
                try fm.trashItem(at: track.url, resultingItemURL: nil)
                try? await database.deleteTrack(url: track.url)
                report.removed.append(track)
            } catch {
                // Wir raten nicht am Fehlercode herum, welche Volumes einen
                // Papierkorb haben: jeder Fehlschlag wird zur Rückfrage. Der
                // endgültige Löschversuch meldet dann seinen eigenen Fehler,
                // falls es auch daran scheitert.
                Self.log.notice("trashItem failed for \(track.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                report.trashUnavailable.append(track)
                if report.trashFailureReason == nil {
                    report.trashFailureReason = error.localizedDescription
                }
            }
        }
        return report
    }

    /// Löscht die Dateien endgültig. Nur aufrufen, nachdem der Nutzer das
    /// ausdrücklich bestätigt hat — hier ist nichts wiederherstellbar.
    public func deletePermanently(_ tracks: [Track]) async -> DeletionReport {
        var report = DeletionReport()
        let fm = FileManager.default

        for track in tracks {
            guard fm.fileExists(atPath: track.url.path) else {
                try? await database.deleteTrack(url: track.url)
                report.removed.append(track)
                continue
            }
            do {
                try fm.removeItem(at: track.url)
                try? await database.deleteTrack(url: track.url)
                report.removed.append(track)
            } catch {
                Self.log.error("removeItem failed for \(track.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                report.failures.append(.init(track: track, message: error.localizedDescription))
            }
        }
        return report
    }

    // MARK: - Helpers

    private func fileModifiedDate(url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.modificationDate] as? Date) ?? Date()
    }
}
