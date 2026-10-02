import XCTest
import AVFoundation
import Foundation
@testable import SetCraftCore

/// Deckt den LRU-Deckel des Speicher-Caches ab. Vorher wuchs `stored`
/// monoton mit jedem angefassten Track — der Prefetch läuft über die ganze
/// Library, und bei ein paar tausend Tracks sind das Gigabyte.
final class WaveformCacheTests: XCTestCase {

    func test_cacheStaysWithinBudget_andKeepsNewest() async throws {
        let urls = try (0..<3).map { _ in try writeToneWAV(durationSeconds: 2) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        // Eine 2-Sekunden-Welle ist ~172 Bins ≈ 2,7 KB. Das Budget reicht damit
        // für eine, nicht für drei.
        let budget = 4_000
        let cache = WaveformCache(memoryBudget: budget)

        for url in urls {
            _ = try await cache.waveform(for: url)
            let bytes = await cache.cachedBytes
            XCTAssertLessThanOrEqual(bytes, budget, "der Deckel muss nach jedem Zugriff halten")
        }

        // Die zuletzt geholte Welle muss noch liegen — sonst rechnete jeder
        // Zugriff neu.
        let newest = try XCTUnwrap(urls.last)
        let stillCached = await cache.isCached(newest)
        XCTAssertTrue(stillCached)

        // Die älteste ist verdrängt.
        let oldest = try XCTUnwrap(urls.first)
        let evicted = await cache.isCached(oldest)
        XCTAssertFalse(evicted, "die älteste Welle muss als erste weichen")
    }

    func test_singleWaveformSurvivesEvenWhenOversized() async throws {
        let url = try writeToneWAV(durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        // Budget 0: der Deckel darf die eine gerade gebrauchte Welle trotzdem
        // nicht wegwerfen.
        let cache = WaveformCache(memoryBudget: 0)
        _ = try await cache.waveform(for: url)

        let stillCached = await cache.isCached(url)
        XCTAssertTrue(stillCached)
        let bytes = await cache.cachedBytes
        XCTAssertGreaterThan(bytes, 0)
    }

    func test_invalidate_freesAccountedBytes() async throws {
        let url = try writeToneWAV(durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = WaveformCache()
        _ = try await cache.waveform(for: url)
        let filled = await cache.cachedBytes
        XCTAssertGreaterThan(filled, 0)

        await cache.invalidate(url)
        let afterInvalidate = await cache.cachedBytes
        XCTAssertEqual(afterInvalidate, 0, "die Buchhaltung darf nicht nachlaufen")

        // Zweimal invalidieren darf den Zähler nicht ins Negative ziehen.
        await cache.invalidate(url)
        let afterSecond = await cache.cachedBytes
        XCTAssertEqual(afterSecond, 0)
    }

    func test_clear_resetsAccounting() async throws {
        let urls = try (0..<2).map { _ in try writeToneWAV(durationSeconds: 1) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        let cache = WaveformCache()
        for url in urls { _ = try await cache.waveform(for: url) }
        let filled = await cache.cachedBytes
        XCTAssertGreaterThan(filled, 0)

        await cache.clear()
        let afterClear = await cache.cachedBytes
        XCTAssertEqual(afterClear, 0)
        for url in urls {
            let cached = await cache.isCached(url)
            XCTAssertFalse(cached)
        }
    }

    // MARK: - Helper

    private func writeToneWAV(durationSeconds: Double) throws -> URL {
        let sampleRate: Double = 44_100
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setcraft-cache-\(UUID().uuidString).wav")
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let ch = buf.floatChannelData![0]
        var phase = 0.0
        for f in 0..<Int(frameCount) {
            phase += 2.0 * .pi * 440.0 / sampleRate
            ch[f] = Float(sin(phase) * 0.5)
        }
        try outFile.write(from: buf)
        return url
    }
}
