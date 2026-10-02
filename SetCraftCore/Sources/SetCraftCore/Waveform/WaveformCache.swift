import Foundation
import OSLog

/// Cached berechnete Waveforms. Erst im Speicher, dann optional in der
/// SQLite-Datenbank, dann erst läuft die teure vDSP-FFT.
/// Mehrere Anfragen auf dieselbe URL teilen sich denselben Task.
public actor WaveformCache {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "WaveformCache")

    private let database: DatabaseService?

    /// Obergrenze für die im Speicher gehaltenen Wellen. Nötig, weil der
    /// Waveform-Prefetch über die ganze Library läuft und `stored` vorher
    /// monoton mitwuchs — verdrängt wurde nie, `clear()` rief niemand.
    /// Eine Welle ist bei `hopSize` 512 rund 86 Bins pro Sekunde, ein
    /// Sechs-Minuten-Track also ~31'000 Bins × 16 Byte ≈ 500 KB. Bei ein paar
    /// tausend Tracks sind das Gigabyte. Verdrängt wird nach LRU; was wegfällt,
    /// kommt beim nächsten Zugriff aus dem DB-Cache zurück, ohne neue FFT.
    private let memoryBudget: Int

    /// macOS darf mehr halten als iOS — dort ist das Speicherbudget des
    /// Prozesses knapp und ein Jetsam-Kill kostet die laufende Wiedergabe.
    public static let defaultMemoryBudget: Int = {
#if os(iOS)
        64 << 20
#else
        192 << 20
#endif
    }()

    public init(database: DatabaseService? = nil, memoryBudget: Int = WaveformCache.defaultMemoryBudget) {
        self.database = database
        self.memoryBudget = max(memoryBudget, 0)
    }

    private var stored: [URL: WaveformData] = [:]
    /// Zugriffsreihenfolge, älteste zuerst. Bleibt klein — die Länge ist durch
    /// `memoryBudget` begrenzt, das lineare Suchen darin fällt nicht auf.
    private var recency: [URL] = []
    private var storedBytes = 0
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
        if let cached = hit(url) { return cached }
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
        if let cached = hit(url) { return cached }
        if let running = inflight[url] { return try await running.value }

        // Erst die DB anfragen.
        if let database, let fromDB = try? await database.loadWaveform(url: url, expectedModifiedAt: mtime) {
            store(fromDB, for: url)
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
            store(result, for: url)
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
        drop(url)
        inflight[url]?.cancel()
        inflight[url] = nil
    }

    public func clear() {
        stored.removeAll()
        recency.removeAll()
        storedBytes = 0
        for (_, t) in inflight { t.cancel() }
        inflight.removeAll()
    }

    /// Belegter Speicher in Byte — für Tests und fürs Log.
    public var cachedBytes: Int { storedBytes }

    /// Liegt die Welle im Speicher? Rührt die Zugriffsreihenfolge **nicht** an,
    /// ist also auch für eine Abfrage im Prefetch gefahrlos.
    public func isCached(_ url: URL) -> Bool { stored[url] != nil }

    // MARK: - LRU

    /// Treffer im Speicher-Cache. Rückt die URL ans jüngste Ende.
    private func hit(_ url: URL) -> WaveformData? {
        guard let data = stored[url] else { return nil }
        touch(url)
        return data
    }

    private func touch(_ url: URL) {
        if let index = recency.lastIndex(of: url) { recency.remove(at: index) }
        recency.append(url)
    }

    private func store(_ data: WaveformData, for url: URL) {
        drop(url)
        stored[url] = data
        storedBytes += Self.byteSize(of: data)
        recency.append(url)
        evictBeyondBudget()
    }

    private func drop(_ url: URL) {
        guard let old = stored.removeValue(forKey: url) else { return }
        storedBytes -= Self.byteSize(of: old)
        if let index = recency.lastIndex(of: url) { recency.remove(at: index) }
    }

    /// Die jüngste Welle bleibt immer liegen, auch wenn sie allein das Budget
    /// sprengt (ein sehr langer Mix) — sonst würfe der Cache genau das weg,
    /// was gerade gebraucht wird, und jeder Zugriff rechnete neu.
    private func evictBeyondBudget() {
        while storedBytes > memoryBudget, recency.count > 1 {
            let victim = recency.removeFirst()
            guard let data = stored.removeValue(forKey: victim) else { continue }
            storedBytes -= Self.byteSize(of: data)
            Self.log.debug("waveform evicted: \(victim.lastPathComponent, privacy: .public)")
        }
    }

    private static func byteSize(of data: WaveformData) -> Int {
        data.bins.count * MemoryLayout<WaveformBin>.stride
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
