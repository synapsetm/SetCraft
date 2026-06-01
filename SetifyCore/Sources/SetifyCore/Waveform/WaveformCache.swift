import Foundation
import OSLog

/// Cached berechnete Waveforms. Erst im Speicher, dann optional in der
/// SQLite-Datenbank, dann erst läuft die teure vDSP-FFT.
/// Mehrere Anfragen auf dieselbe URL teilen sich denselben Task.
public actor WaveformCache {

    private static let log = Logger(subsystem: "ch.beat.buehler.Setify", category: "WaveformCache")

    private let database: DatabaseService?

    public init(database: DatabaseService? = nil) {
        self.database = database
    }

    private var stored: [URL: WaveformData] = [:]
    private var inflight: [URL: Task<WaveformData, Error>] = [:]

    public func waveform(for url: URL) async throws -> WaveformData {
        if let cached = stored[url] { return cached }
        if let running = inflight[url] { return try await running.value }

        let mtime = (try? fileModifiedDate(url: url)) ?? Date()

        // Erst die DB anfragen.
        if let database, let fromDB = try? await database.loadWaveform(url: url, expectedModifiedAt: mtime) {
            stored[url] = fromDB
            Self.log.debug("waveform DB-hit: \(url.lastPathComponent, privacy: .public)")
            return fromDB
        }

        // Sonst: berechnen und speichern.
        let database = database
        let task = Task<WaveformData, Error>.detached(priority: .utility) {
            let computed = try WaveformAnalyzer.analyze(url: url)
            if let database {
                try? await database.saveWaveform(computed, url: url, modifiedAt: mtime)
            }
            return computed
        }
        inflight[url] = task
        do {
            let result = try await task.value
            stored[url] = result
            inflight[url] = nil
            return result
        } catch {
            inflight[url] = nil
            throw error
        }
    }

    public func invalidate(_ url: URL) {
        stored[url] = nil
        inflight[url]?.cancel()
        inflight[url] = nil
    }

    public func clear() {
        stored.removeAll()
        for (_, t) in inflight { t.cancel() }
        inflight.removeAll()
    }

    private func fileModifiedDate(url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.modificationDate] as? Date) ?? Date()
    }
}
