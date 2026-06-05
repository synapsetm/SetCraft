import Foundation
import OSLog

/// Orchestriert das Lesen und Schreiben von Tracks: prüft zuerst den
/// SQLite-Cache, fällt bei `stale`-Werten (Datei-Modifikationsdatum
/// passt nicht mehr) auf TagLib zurück. Schreibvorgänge gehen weiterhin
/// durch `TagLibTrackStore` (Datei = Quelle der Wahrheit) und
/// aktualisieren anschliessend den Cache.
public actor LibraryRepository: TrackStore {

    private static let log = Logger(subsystem: "ch.beat.buehler.Setify", category: "LibraryRepository")

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
            let fresh = try TagReader.read(url: url)
            try? await database.saveTrack(fresh, modifiedAt: mtime)
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

    // MARK: - Helpers

    private func fileModifiedDate(url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.modificationDate] as? Date) ?? Date()
    }
}
