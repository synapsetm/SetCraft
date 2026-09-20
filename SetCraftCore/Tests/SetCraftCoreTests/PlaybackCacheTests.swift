import XCTest
@testable import SetCraftCore

/// Der Wiedergabe-Cache hält höchstens zwei Dateien: den laufenden Track und
/// den vorausgeholten. Getestet wird, was schiefgehen kann, ohne dass man es
/// hört — eine halbe Kopie, ein nicht wiedergefundener Eintrag, ein Cache, der
/// über die Grenze wächst.
/// Sammelt Ergebnisse aus nebenläufigen Closures. Swift 6 lässt das Mutieren
/// einer eingefangenen `var` dort nicht zu.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PlaybackCache.StoreResult] = []

    func add(_ result: PlaybackCache.StoreResult) {
        lock.withLock { results.append(result) }
    }

    var all: [PlaybackCache.StoreResult] {
        lock.withLock { results }
    }
}

final class PlaybackCacheTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PlaybackCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Legt eine Datei mit unterscheidbarem Inhalt an.
    private func makeFile(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Die Cache-URL eines erfolgreichen `store`, sonst `nil`.
    @discardableResult
    private func store(_ url: URL) -> URL? {
        if case .cached(let cached) = PlaybackCache.shared.store(url) { return cached }
        return nil
    }

    func test_store_legtKopieAn_undFindetSieWieder() throws {
        let source = try makeFile("a.mp3", bytes: [1, 2, 3, 4, 5])

        let unwrapped = try XCTUnwrap(store(source), "Kopie sollte anlegbar sein")

        XCTAssertNotEqual(unwrapped, source, "Es muss eine eigene Datei sein")
        XCTAssertEqual(try Data(contentsOf: unwrapped), Data([1, 2, 3, 4, 5]),
                       "Inhalt muss byte-gleich sein — halbe Kopien werden sonst als Stille gespielt")
        XCTAssertEqual(PlaybackCache.shared.existingCopy(of: source), unwrapped)
    }

    func test_derselbeQuellpfad_ergibtdenselbenCachenamen() throws {
        let source = try makeFile("b.mp3", bytes: [9, 9])

        let first = try XCTUnwrap(store(source))
        let second = try XCTUnwrap(store(source))

        XCTAssertEqual(first, second, "Der Name wird aus dem Quellpfad abgeleitet, nicht geraten")
    }

    func test_unbekannteQuelle_hatkeineKopie() throws {
        let source = try makeFile("c.mp3", bytes: [7])
        // Bewusst NICHT gespeichert.
        XCTAssertNil(PlaybackCache.shared.existingCopy(of: source))
    }

    /// Kapazität 4 seit 2026-09-20: laufender Track plus die drei
    /// vorausgeholten. Fünf Dateien passen nicht, die älteste muss weichen.
    func test_cache_haeltNurDieVierJuengsten() throws {
        let files = try (1...5).map { try makeFile("n\($0).mp3", bytes: [UInt8($0)]) }
        for file in files { store(file) }

        for survivor in files.dropFirst() {
            XCTAssertNotNil(PlaybackCache.shared.existingCopy(of: survivor),
                            "\(survivor.lastPathComponent) gehört zu den vier jüngsten")
        }
        XCTAssertNil(PlaybackCache.shared.existingCopy(of: files[0]),
                     "die älteste muss verdrängt sein — der Cache ist kein Archiv")
    }

    func test_erneuterZugriff_schuetztVorVerdraengung() throws {
        let a = try makeFile("a2.mp3", bytes: [1])
        let b = try makeFile("b2.mp3", bytes: [2])
        let rest = try (1...3).map { try makeFile("r\($0).mp3", bytes: [UInt8(10 + $0)]) }

        store(a)
        store(b)
        for file in rest.dropLast() { store(file) }
        // a wieder anfassen — damit ist b der älteste Eintrag.
        _ = PlaybackCache.shared.existingCopy(of: a)
        store(rest[rest.count - 1])

        XCTAssertNotNil(PlaybackCache.shared.existingCopy(of: a),
                        "gerade benutzt, darf nicht verdrängt werden")
        XCTAssertNil(PlaybackCache.shared.existingCopy(of: b))
    }

    /// Beim Durchskippen holen `prefetch` und `prefetchAhead` auf getrennten
    /// Queues oft DIESELBE Datei. Beide kopieren, der zweite `moveItem`
    /// scheitert am inzwischen vorhandenen Ziel — das ist ein Wettlauf, kein
    /// Fehler, und hat dem Nutzer „The track could not be copied for playback"
    /// angezeigt, obwohl alles in Ordnung war.
    func test_gleichzeitigesStore_derselbenQuelle_istkeinFehler() throws {
        let source = try makeFile("race.mp3", bytes: Array(repeating: 42, count: 8_192))

        let done = expectation(description: "beide Läufe fertig")
        done.expectedFulfillmentCount = 2
        let collected = ResultBox()

        for _ in 0..<2 {
            DispatchQueue.global().async {
                collected.add(PlaybackCache.shared.store(source))
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)

        for result in collected.all {
            guard case .cached = result else {
                return XCTFail("Beide Läufe müssen `.cached` liefern, war: \(result)")
            }
        }
        XCTAssertNotNil(PlaybackCache.shared.existingCopy(of: source))
    }

    /// Eine Quelle, die kürzer liefert als angekündigt, darf NICHT als gültige
    /// Kopie durchgehen — genau daraus entsteht sonst Stille bei laufendem
    /// Playhead.
    func test_verschwundeneQuelle_meldetSourceIncomplete() throws {
        let source = try makeFile("gone.mp3", bytes: [1, 2, 3])
        try FileManager.default.removeItem(at: source)

        guard case .sourceIncomplete = PlaybackCache.shared.store(source) else {
            return XCTFail("Eine unlesbare Quelle muss als Quellproblem gemeldet werden")
        }
    }

    #if os(macOS)
    /// Auf dem Mac liegt die Bibliothek im Home des Nutzers. Diese Dateien zu
    /// kopieren wäre reine Verschwendung — sie können nicht wegen eines
    /// Netzausfalls verschwinden. Kopiert wird nur von Netz-Volumes.
    func test_lokaleDatei_wirdaufMacOSnichtkopiert() throws {
        let source = try makeFile("local.mp3", bytes: [1])
        XCTAssertFalse(PlaybackCache.shared.shouldCache(source))
    }
    #endif
}
