import XCTest
@testable import SetCraftCore

/// Der Wiedergabe-Cache hält höchstens zwei Dateien: den laufenden Track und
/// den vorausgeholten. Getestet wird, was schiefgehen kann, ohne dass man es
/// hört — eine halbe Kopie, ein nicht wiedergefundener Eintrag, ein Cache, der
/// über die Grenze wächst.
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

    func test_store_legtKopieAn_undFindetSieWieder() throws {
        let source = try makeFile("a.mp3", bytes: [1, 2, 3, 4, 5])

        let copy = PlaybackCache.shared.store(source)
        let unwrapped = try XCTUnwrap(copy, "Kopie sollte anlegbar sein")

        XCTAssertNotEqual(unwrapped, source, "Es muss eine eigene Datei sein")
        XCTAssertEqual(try Data(contentsOf: unwrapped), Data([1, 2, 3, 4, 5]),
                       "Inhalt muss byte-gleich sein — halbe Kopien werden sonst als Stille gespielt")
        XCTAssertEqual(PlaybackCache.shared.existingCopy(of: source), unwrapped)
    }

    func test_derselbeQuellpfad_ergibtdenselbenCachenamen() throws {
        let source = try makeFile("b.mp3", bytes: [9, 9])

        let first = try XCTUnwrap(PlaybackCache.shared.store(source))
        let second = try XCTUnwrap(PlaybackCache.shared.store(source))

        XCTAssertEqual(first, second, "Der Name wird aus dem Quellpfad abgeleitet, nicht geraten")
    }

    func test_unbekannteQuelle_hatkeineKopie() throws {
        let source = try makeFile("c.mp3", bytes: [7])
        // Bewusst NICHT gespeichert.
        XCTAssertNil(PlaybackCache.shared.existingCopy(of: source))
    }

    func test_cache_haeltNurDieZweiJuengsten() throws {
        let first  = try makeFile("first.mp3",  bytes: [1])
        let second = try makeFile("second.mp3", bytes: [2])
        let third  = try makeFile("third.mp3",  bytes: [3])

        PlaybackCache.shared.store(first)
        PlaybackCache.shared.store(second)
        PlaybackCache.shared.store(third)

        XCTAssertNotNil(PlaybackCache.shared.existingCopy(of: third),  "jüngste bleibt")
        XCTAssertNotNil(PlaybackCache.shared.existingCopy(of: second), "zweitjüngste bleibt")
        XCTAssertNil(PlaybackCache.shared.existingCopy(of: first),
                     "die älteste muss verdrängt sein — der Cache ist kein Archiv")
    }

    func test_erneuterZugriff_schuetztVorVerdraengung() throws {
        let a = try makeFile("a2.mp3", bytes: [1])
        let b = try makeFile("b2.mp3", bytes: [2])
        let c = try makeFile("c2.mp3", bytes: [3])

        PlaybackCache.shared.store(a)
        PlaybackCache.shared.store(b)
        // a wieder anfassen — damit ist b der älteste Eintrag.
        _ = PlaybackCache.shared.existingCopy(of: a)
        PlaybackCache.shared.store(c)

        XCTAssertNotNil(PlaybackCache.shared.existingCopy(of: a),
                        "gerade benutzt, darf nicht verdrängt werden")
        XCTAssertNil(PlaybackCache.shared.existingCopy(of: b))
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
