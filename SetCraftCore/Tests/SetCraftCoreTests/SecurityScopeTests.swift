import XCTest
@testable import SetCraftCore

/// Deckt die Regel ab, wegen der es diesen Typ gibt: ein Quellenwechsel darf
/// den Scope nicht schliessen, solange noch eine Analyse oder ein Tag-Write
/// darauf arbeitet.
final class SecurityScopeTests: XCTestCase {

    /// Zählt `stopAccessingSecurityScopedResource()`-Aufrufe, ohne dass eine
    /// echte Sandbox-Extension nötig ist.
    private final class StopCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func increment() {
            lock.lock(); value += 1; lock.unlock()
        }
    }

    private func makeScope(
        _ path: String = "/Volumes/NAS/01_Downloads",
        granted: Bool = true,
        stops: StopCounter = StopCounter()
    ) -> SecurityScope {
        SecurityScope(
            url: URL(fileURLWithPath: path),
            startAccess: { _ in granted },
            stopAccess: { _ in stops.increment() }
        )
    }

    // MARK: - SecurityScope

    func test_requestRelease_withoutUsers_closesImmediately() {
        let stops = StopCounter()
        let scope = makeScope(stops: stops)
        XCTAssertTrue(scope.isActive)

        scope.requestRelease()

        XCTAssertFalse(scope.isActive)
        XCTAssertEqual(stops.count, 1)
    }

    func test_requestRelease_withLiveToken_staysOpenUntilTokenReturns() {
        let stops = StopCounter()
        let scope = makeScope(stops: stops)
        let token = scope.acquire()
        XCTAssertNotNil(token)

        scope.requestRelease()

        // Genau der Fall aus dem Bug: Ordner gewechselt, Schreibvorgang läuft.
        XCTAssertTrue(scope.isActive)
        XCTAssertEqual(stops.count, 0)

        token?.release()

        XCTAssertFalse(scope.isActive)
        XCTAssertEqual(stops.count, 1)
    }

    func test_multipleTokens_lastOneCloses() {
        let stops = StopCounter()
        let scope = makeScope(stops: stops)
        let first = scope.acquire()
        let second = scope.acquire()

        scope.requestRelease()
        first?.release()
        XCTAssertTrue(scope.isActive)

        second?.release()
        XCTAssertFalse(scope.isActive)
        XCTAssertEqual(stops.count, 1)
    }

    func test_release_isIdempotent() {
        let stops = StopCounter()
        let scope = makeScope(stops: stops)
        let token = scope.acquire()
        scope.requestRelease()

        token?.release()
        token?.release()
        token?.release()

        XCTAssertEqual(stops.count, 1)
    }

    func test_droppedToken_releasesViaDeinit() {
        let stops = StopCounter()
        let scope = makeScope(stops: stops)
        do {
            let token = scope.acquire()
            XCTAssertNotNil(token)
            scope.requestRelease()
            XCTAssertTrue(scope.isActive)
        }
        XCTAssertFalse(scope.isActive)
        XCTAssertEqual(stops.count, 1)
    }

    func test_deniedAccess_neverOpensAndNeverStops() {
        let stops = StopCounter()
        let scope = makeScope(granted: false, stops: stops)

        XCTAssertFalse(scope.didStartAccess)
        XCTAssertNil(scope.acquire())

        scope.requestRelease()
        XCTAssertEqual(stops.count, 0)
    }

    func test_closedScope_cannotBeAcquiredAgain() {
        let scope = makeScope()
        scope.requestRelease()
        XCTAssertNil(scope.acquire())
    }

    // MARK: - SecurityScopeRegistry

    private func makeRegistry(
        granted: Bool = true,
        stops: StopCounter = StopCounter()
    ) -> SecurityScopeRegistry {
        SecurityScopeRegistry(makeScope: { url in
            SecurityScope(
                url: url,
                startAccess: { _ in granted },
                stopAccess: { _ in stops.increment() }
            )
        })
    }

    func test_activate_switchesActiveSource() {
        let registry = makeRegistry()
        XCTAssertTrue(registry.activate(URL(fileURLWithPath: "/Volumes/NAS/A")))
        XCTAssertEqual(registry.activeURL?.path, "/Volumes/NAS/A")

        XCTAssertTrue(registry.activate(URL(fileURLWithPath: "/Volumes/NAS/B")))
        XCTAssertEqual(registry.activeURL?.path, "/Volumes/NAS/B")
    }

    func test_deniedActivate_leavesPreviousSourceUntouched() {
        let stops = StopCounter()
        let registry = makeRegistry(granted: false, stops: stops)

        XCTAssertFalse(registry.activate(URL(fileURLWithPath: "/Volumes/NAS/A")))
        XCTAssertNil(registry.activeURL)
        XCTAssertEqual(stops.count, 0)
    }

    func test_unscopedActivate_succeedsWithoutGrant() {
        // NSOpenPanel-URLs sind nicht security-scoped, bleiben aber nutzbar.
        let registry = makeRegistry(granted: false)
        XCTAssertTrue(registry.activate(URL(fileURLWithPath: "/Users/dj/Music"), requireScope: false))
        XCTAssertEqual(registry.activeURL?.path, "/Users/dj/Music")
    }

    func test_tokenTakenBeforeSwitch_keepsOldSourceOpen() {
        let stops = StopCounter()
        let registry = makeRegistry(stops: stops)
        let old = URL(fileURLWithPath: "/Volumes/NAS/01_Downloads")
        registry.activate(old)

        let token = registry.token(for: old.appendingPathComponent("track.mp3"))
        XCTAssertNotNil(token)

        registry.activate(URL(fileURLWithPath: "/Volumes/NAS/02_Sets"))
        XCTAssertEqual(stops.count, 0, "alte Quelle darf noch nicht geschlossen sein")

        token?.release()
        XCTAssertEqual(stops.count, 1)
    }

    func test_tokenForRetiredSource_stillResolvesWhileWorkIsRunning() {
        let registry = makeRegistry()
        let old = URL(fileURLWithPath: "/Volumes/NAS/01_Downloads")
        registry.activate(old)

        let analysisToken = registry.token(for: old.appendingPathComponent("a.mp3"))
        registry.activate(URL(fileURLWithPath: "/Volumes/NAS/02_Sets"))

        // Der Tag-Write zieht sein eigenes Token — die Quelle ist abgemeldet,
        // aber noch offen, also muss er sie finden.
        let saveToken = registry.token(for: old.appendingPathComponent("a.mp3"))
        XCTAssertNotNil(saveToken)

        analysisToken?.release()
        saveToken?.release()

        XCTAssertNil(registry.token(for: old.appendingPathComponent("a.mp3")))
    }

    func test_token_matchesOnPathBoundaryOnly() {
        let registry = makeRegistry()
        registry.activate(URL(fileURLWithPath: "/Volumes/NAS/Set"))

        XCTAssertNotNil(registry.token(for: URL(fileURLWithPath: "/Volumes/NAS/Set/a.mp3")))
        XCTAssertNil(registry.token(for: URL(fileURLWithPath: "/Volumes/NAS/SetCraft/a.mp3")))
    }

    func test_token_prefersMostSpecificSource() {
        let registry = makeRegistry()
        let outer = URL(fileURLWithPath: "/Volumes/NAS")
        let inner = URL(fileURLWithPath: "/Volumes/NAS/01_Downloads")
        registry.activate(outer)
        let outerToken = registry.token(for: inner.appendingPathComponent("a.mp3"))
        registry.activate(inner)

        let token = registry.token(for: inner.appendingPathComponent("a.mp3"))
        XCTAssertEqual(token?.scopeURL.path, inner.path)

        outerToken?.release()
        token?.release()
    }

    func test_deactivate_thenNoTokens() {
        let registry = makeRegistry()
        let folder = URL(fileURLWithPath: "/Volumes/NAS/01_Downloads")
        registry.activate(folder)
        registry.deactivate()

        XCTAssertNil(registry.activeURL)
        XCTAssertNil(registry.token(for: folder.appendingPathComponent("a.mp3")))
    }

    func test_releaseAll_closesEverything() {
        let stops = StopCounter()
        let registry = makeRegistry(stops: stops)
        let first = URL(fileURLWithPath: "/Volumes/NAS/A")
        registry.activate(first)
        let token = registry.token(for: first.appendingPathComponent("a.mp3"))
        registry.activate(URL(fileURLWithPath: "/Volumes/NAS/B"))

        registry.releaseAll()
        XCTAssertNil(registry.activeURL)
        XCTAssertEqual(stops.count, 1, "die Quelle mit laufender Arbeit bleibt bis zur Tokenrückgabe offen")

        token?.release()
        XCTAssertEqual(stops.count, 2)
    }

    // MARK: - Begleit-Scopes (Playlist-Quellen)

    func test_companions_coverTheirFiles_andCloseWithActiveSource() {
        let stops = StopCounter()
        let registry = makeRegistry(stops: stops)
        registry.activate(URL(fileURLWithPath: "/Volumes/share/set.m3u8"))
        XCTAssertTrue(registry.addCompanion(URL(fileURLWithPath: "/Volumes/share/Musik")))

        XCTAssertEqual(registry.openURLs.map(\.path), ["/Volumes/share/set.m3u8", "/Volumes/share/Musik"])
        let token = registry.token(for: URL(fileURLWithPath: "/Volumes/share/Musik/a.mp3"))
        XCTAssertEqual(token?.scopeURL.path, "/Volumes/share/Musik")

        registry.activate(URL(fileURLWithPath: "/Volumes/share/Andere"))
        XCTAssertEqual(stops.count, 1, "M3U-Scope zu, Musik-Ordner hält das Token noch offen")
        token?.release()
        XCTAssertEqual(stops.count, 2)
        XCTAssertNil(registry.token(for: URL(fileURLWithPath: "/Volumes/share/Musik/a.mp3")))
    }

    func test_companion_withoutActiveSource_isRejected() {
        let registry = makeRegistry()
        XCTAssertFalse(registry.addCompanion(URL(fileURLWithPath: "/Volumes/share/Musik")))
    }

    func test_deniedCompanion_isNotAdded() {
        let registry = makeRegistry(granted: false)
        registry.activate(URL(fileURLWithPath: "/a.m3u8"), requireScope: false)
        XCTAssertFalse(registry.addCompanion(URL(fileURLWithPath: "/Musik")))
        XCTAssertEqual(registry.openURLs.count, 1)
    }

    func test_deactivate_closesCompanions() {
        let stops = StopCounter()
        let registry = makeRegistry(stops: stops)
        registry.activate(URL(fileURLWithPath: "/a.m3u8"))
        registry.addCompanion(URL(fileURLWithPath: "/Musik"))
        registry.deactivate()
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(registry.openURLs, [])
    }
}
