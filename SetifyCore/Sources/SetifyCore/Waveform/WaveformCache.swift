import Foundation

/// In-Memory-Cache für berechnete Waveforms. Ein einzelner laufender
/// Analyse-Job pro URL — parallele Anfragen warten auf dasselbe Resultat.
/// Phase 5 kann das durch einen Disk-Cache (`Application Support/.../*.bin`)
/// ergänzen, ohne die Schnittstelle zu brechen.
public actor WaveformCache {

    public init() {}

    private var stored: [URL: WaveformData] = [:]
    private var inflight: [URL: Task<WaveformData, Error>] = [:]

    /// Liefert die Waveform-Daten zur URL. Wenn parallel mehrere Aufrufer
    /// dieselbe URL anfragen, wartet jeder auf das gemeinsame Task-Result.
    public func waveform(for url: URL) async throws -> WaveformData {
        if let cached = stored[url] { return cached }

        if let running = inflight[url] {
            return try await running.value
        }

        let task = Task<WaveformData, Error>.detached(priority: .utility) {
            try WaveformAnalyzer.analyze(url: url)
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
}
