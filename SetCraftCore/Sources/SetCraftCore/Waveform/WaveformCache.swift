import Foundation
import OSLog

/// Cached berechnete Waveforms. Erst im Speicher, dann optional in der
/// SQLite-Datenbank, dann erst läuft die teure vDSP-FFT.
/// Mehrere Anfragen auf dieselbe URL teilen sich denselben Task.
public actor WaveformCache {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "WaveformCache")

    private let database: DatabaseService?

    public init(database: DatabaseService? = nil) {
        self.database = database
    }

    private var stored: [URL: WaveformData] = [:]
    private var inflight: [URL: Task<WaveformData, Error>] = [:]
    /// Interessenten an Zwischenständen pro URL. Mehrere Aufrufer teilen sich
    /// dieselbe laufende Berechnung und bekommen alle dieselben Teilstände.
    private var partialObservers: [URL: [@Sendable (WaveformData) -> Void]] = [:]

    /// Liefert die Welle. `onPartial` — falls gesetzt — bekommt während der
    /// Berechnung Zwischenstände, damit die UI nicht bis zum Schluss leer
    /// bleibt. Zwischenstände kommen nur, wenn wirklich gerechnet wird: aus
    /// Speicher- oder DB-Cache kommt das Ergebnis sofort und vollständig.
    public func waveform(
        for url: URL,
        onPartial: (@Sendable (WaveformData) -> Void)? = nil
    ) async throws -> WaveformData {
        if let cached = stored[url] { return cached }
        if let onPartial { partialObservers[url, default: []].append(onPartial) }
        if let running = inflight[url] { return try await running.value }

        // Der `stat` geht bei einer FileProvider-URL (iCloud, NAS/SMB) zum
        // Provider und braucht dort Sekunden statt Mikrosekunden. Bis hierher
        // lief er synchron IM Actor und hielt damit alles an, was sonst noch
        // über den Actor will: die Zwischenstände des laufenden Tracks
        // (`publish`) genauso wie die Anfrage für den neu geladenen. Genau der
        // Gerätebefund vom 2026-09-21 — stehende Welle beim laufenden Track,
        // gar keine beim neuen. Jetzt auf einer eigenen Queue, nicht im
        // Cooperative Pool (CLAUDE.md).
        let mtime = await Self.modifiedDate(of: url) ?? Date()

        // Der Actor war während des `await` frei: ein zweiter Aufrufer für
        // dieselbe URL kann inzwischen fertig geworden oder gestartet sein.
        if let cached = stored[url] { return cached }
        if let running = inflight[url] { return try await running.value }

        // Erst die DB anfragen.
        if let database, let fromDB = try? await database.loadWaveform(url: url, expectedModifiedAt: mtime) {
            stored[url] = fromDB
            Self.log.debug("waveform DB-hit: \(url.lastPathComponent, privacy: .public)")
            return fromDB
        }

        // Sonst: berechnen und speichern.
        let database = database
        let task = Task<WaveformData, Error>.detached(priority: .utility) { [weak self] in
            // Gelesen wird aus der Wiedergabe-Kopie, wenn es eine gibt —
            // dieselbe Regel, nach der die BPM/Key-Analyse schon liest
            // (`LibraryStore.analyze`). Der gerade geöffnete Track liegt dort
            // lokal vor; die Welle hängt damit nicht am FileProvider und
            // konkurriert nicht mit der Vorausschau um dieselbe Leitung.
            // Ohne Kopie (Mac, lokale Datei) bleibt es bei der Quelle.
            let readURL = PlaybackCache.shared.existingCopy(of: url) ?? url
            let computed = try WaveformAnalyzer.analyze(url: readURL) { partial in
                // `onPartial` läuft auf dem Decoder-Thread — den Zwischenstand
                // deshalb über den Actor verteilen, nicht direkt.
                Task { await self?.publish(partial, for: url) }
            }
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
            partialObservers[url] = nil
            return result
        } catch {
            inflight[url] = nil
            partialObservers[url] = nil
            // Bis hierher endete ein Fehlschlag lautlos: `PlayerStore`
            // verschluckt ihn, und im Gerätelog stand nichts. Eine fehlende
            // Welle war damit nicht nachvollziehbar.
            Self.log.error("waveform failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Reicht einen Zwischenstand an alle Interessenten weiter.
    private func publish(_ partial: WaveformData, for url: URL) {
        guard let observers = partialObservers[url] else { return }
        for observer in observers { observer(partial) }
    }

    /// Bequemer Weg für Views: ein Strom aus Zwischenständen, der mit dem
    /// fertigen Ergebnis endet. Bricht der Consumer ab (Track gewechselt),
    /// endet auch der Strom — die laufende Berechnung selbst läuft weiter und
    /// landet im Cache, damit die Arbeit nicht verloren ist.
    public nonisolated func stream(for url: URL) -> AsyncThrowingStream<WaveformData, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let final = try await waveform(for: url) { partial in
                        continuation.yield(partial)
                    }
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    /// Eigene Queue für den `stat`. Blockiert der Provider, blockiert genau
    /// ein Thread hier — nicht der Actor und nicht der Cooperative Pool, dessen
    /// enges Thread-Budget ein sekundenlang hängender Aufruf sprengt.
    private static let metadataQueue = DispatchQueue(
        label: "ch.buehler.beat.SetCraft.waveform-metadata",
        qos: .utility
    )

    /// Änderungsdatum der QUELLE — der DB-Cache ist darüber geschlüsselt, auch
    /// wenn aus der Wiedergabe-Kopie gerechnet wird. Kommt nichts zurück
    /// (offline, Platzhalter), setzt der Aufrufer `Date()` ein und rechnet neu.
    private nonisolated static func modifiedDate(of url: URL) async -> Date? {
        await withCheckedContinuation { continuation in
            metadataQueue.async {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                continuation.resume(returning: attrs?[.modificationDate] as? Date)
            }
        }
    }
}
