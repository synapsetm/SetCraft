import XCTest
@testable import SetCraftCore

// MARK: - HTTP-Doppel

/// Routen und Aufzeichnung für `StubURLProtocol`. Eigene Klasse mit Lock, weil
/// URLSession die Requests auf ihren eigenen Threads stellt.
private final class StubResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(fragment: String, status: Int, body: Data, headers: [String: String])] = []
    private var requests: [URLRequest] = []

    func route(_ fragment: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        routes.append((fragment, status, Data(json.utf8), headers))
    }

    func handle(_ request: URLRequest) -> (Int, Data, [String: String]) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let target = request.url?.absoluteString ?? ""
        if let route = routes.first(where: { target.contains($0.fragment) }) {
            return (route.status, route.body, route.headers)
        }
        return (404, Data("{}".utf8), [:])
    }

    var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var requestCount: Int { recorded.count }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: StubResponder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body, headers) = responder.handle(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// In-Memory-Cache, um Treffer und Schreibvorgänge zählen zu können.
private actor MemoryCache: CatalogResponseCache {
    private var storage: [String: (Data, Date)] = [:]
    private var hits = 0
    private var writes = 0

    func cachedResponse(forKey key: String, maxAge: TimeInterval) async -> Data? {
        guard let entry = storage[key], Date().timeIntervalSince(entry.1) <= maxAge else { return nil }
        hits += 1
        return entry.0
    }

    func store(_ data: Data, forKey key: String) async {
        storage[key] = (data, Date())
        writes += 1
    }

    func counters() -> (hits: Int, writes: Int) { (hits, writes) }
}

// MARK: - Fixtures (Form wie von api.discogs.com)

private let searchJSON = """
{"pagination":{"page":1,"pages":1,"per_page":10,"items":2},
 "results":[
   {"id":1,"title":"The Persuader - Stockholm","year":"1999","catno":"SK032",
    "label":["Svek"],"format":["Vinyl","12\\"","33 ⅓ RPM"],"type":"release"},
   {"id":35094713,"title":"The Persuader - Stockholm","year":"1999","catno":"SK032CD",
    "label":["Svek"],"format":["CD"],"type":"release"}]}
"""

private let releaseJSON = """
{"id":1,"title":"Stockholm","year":1999,
 "artists":[{"name":"The Persuader","anv":"","join":""}],
 "labels":[{"name":"Svek","catno":"SK032"}],
 "tracklist":[
   {"position":"","type_":"heading","title":"Side A","duration":""},
   {"position":"A","type_":"track","title":"Östermalm","duration":"4:45"},
   {"position":"B1","type_":"track","title":"Vasastaden","duration":"6:11"},
   {"position":"B2","type_":"track","title":"Kungsholmen","duration":"2:49"}]}
"""

private let remixReleaseJSON = """
{"id":99,"title":"Mekong Delta","year":2008,
 "artists":[{"name":"Len Faki","anv":"","join":""}],
 "labels":[{"name":"Ostgut Ton (2)","catno":"OSTGUT 14"}],
 "tracklist":[
   {"position":"A","type_":"track","title":"Mekong Delta (Original Mix)","duration":"7:30"},
   {"position":"B","type_":"track","title":"Mekong Delta (Radio Edit)","duration":"3:20"}]}
"""

private func makeClient(
    responder: StubResponder,
    token: String? = nil,
    cache: CatalogResponseCache? = nil
) -> DiscogsClient {
    StubURLProtocol.responder = responder
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return DiscogsClient(
        configuration: DiscogsConfiguration(token: token, userAgent: "SetCraftTests/1.0"),
        session: URLSession(configuration: configuration),
        cache: cache
    )
}

// MARK: - Tests

final class DiscogsResolverTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func test_resolvesTrackFromTracklist() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: searchJSON)
        responder.route("releases/1", json: releaseJSON)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        let matches = try await resolver.search(
            CatalogQuery(artist: "The Persuader", title: "Vasastaden", durationSeconds: 371)
        )

        let best = try XCTUnwrap(matches.first)
        XCTAssertEqual(best.artist, "The Persuader")
        XCTAssertEqual(best.title, "Vasastaden")
        XCTAssertEqual(best.album, "Stockholm")
        XCTAssertEqual(best.label, "Svek")
        XCTAssertEqual(best.catalogNumber, "SK032")
        XCTAssertEqual(best.year, 1999)
        XCTAssertEqual(best.durationSeconds, 371)
        XCTAssertEqual(best.reference, "discogs:release/1#B1")
        XCTAssertGreaterThan(best.score, 0.9)
    }

    func test_headingEntries_areSkipped() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: searchJSON)
        responder.route("releases/1", json: releaseJSON)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        let matches = try await resolver.search(
            CatalogQuery(artist: "The Persuader", title: "Side A")
        )
        XCTAssertFalse(matches.contains { $0.title == "Side A" })
    }

    func test_durationMismatch_lowersScore() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: searchJSON)
        responder.route("releases/1", json: releaseJSON)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        // Titel passt, Dauer ist zwei Minuten daneben → das ist eine andere Fassung.
        let matches = try await resolver.search(
            CatalogQuery(artist: "The Persuader", title: "Vasastaden", durationSeconds: 240)
        )
        let best = try XCTUnwrap(matches.first)
        XCTAssertLessThan(best.score, 0.8, "Dauer-Abweichung muss den Treffer abwerten")
    }

    func test_mixVersionGuidesChoiceBetweenVersions() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: """
        {"results":[{"id":99,"title":"Len Faki - Mekong Delta","type":"release","format":["Vinyl"]}]}
        """)
        responder.route("releases/99", json: remixReleaseJSON)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        let matches = try await resolver.search(
            CatalogQuery(artist: "Len Faki", title: "Mekong Delta",
                         mixVersion: "Radio Edit", durationSeconds: 200)
        )
        XCTAssertEqual(try XCTUnwrap(matches.first).title, "Mekong Delta (Radio Edit)")
    }

    func test_labelDisambiguationSuffix_isStripped() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: """
        {"results":[{"id":99,"title":"Len Faki - Mekong Delta","type":"release"}]}
        """)
        responder.route("releases/99", json: remixReleaseJSON)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        let matches = try await resolver.search(
            CatalogQuery(artist: "Len Faki", title: "Mekong Delta", durationSeconds: 450)
        )
        XCTAssertEqual(try XCTUnwrap(matches.first).label, "Ostgut Ton")
    }

    func test_emptySearchResult_yieldsNoMatches() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: #"{"results":[]}"#)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        let matches = try await resolver.search(CatalogQuery(artist: "Nobody", title: "Nothing"))
        XCTAssertTrue(matches.isEmpty)
    }

    func test_queryWithoutTitle_makesNoRequest() async throws {
        let responder = StubResponder()
        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        let matches = try await resolver.search(CatalogQuery(artist: "Len Faki", title: ""))
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(responder.requestCount, 0)
    }

    func test_catalogNumberSearch_retriesWithoutCatnoOnMiss() async throws {
        let responder = StubResponder()
        // Der Stub unterscheidet nicht nach Parametern, darum zählen wir Requests.
        responder.route("database/search", json: #"{"results":[]}"#)

        let resolver = DiscogsResolver(client: makeClient(responder: responder))
        _ = try await resolver.search(
            CatalogQuery(artist: "The Persuader", title: "Vasastaden", catalogNumber: "SK032A")
        )
        XCTAssertEqual(responder.requestCount, 2, "Verstümmelte Katalognummer bekommt einen zweiten Versuch")
    }

    func test_onlyTopResultsAreResolved() async throws {
        let responder = StubResponder()
        responder.route("database/search", json: searchJSON)
        responder.route("releases/1", json: releaseJSON)
        responder.route("releases/35094713", json: releaseJSON)

        let resolver = DiscogsResolver(client: makeClient(responder: responder), releaseFetchLimit: 1)
        _ = try await resolver.search(
            CatalogQuery(artist: "The Persuader", title: "Vasastaden", durationSeconds: 371)
        )
        XCTAssertEqual(responder.requestCount, 2, "Suche plus genau ein Release")
    }
}

final class DiscogsClientTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func test_requestCarriesUserAgentAndNoAuthWithoutToken() async throws {
        let responder = StubResponder()
        responder.route("releases/1", json: releaseJSON)
        let client = makeClient(responder: responder)
        _ = try await client.release(id: 1)

        let request = try XCTUnwrap(responder.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SetCraftTests/1.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_tokenIsSentAsDiscogsAuthorization() async throws {
        let responder = StubResponder()
        responder.route("releases/1", json: releaseJSON)
        let client = makeClient(responder: responder, token: "abc123")
        _ = try await client.release(id: 1)

        let request = try XCTUnwrap(responder.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Discogs token=abc123")
    }

    func test_rateLimitDependsOnToken() {
        XCTAssertEqual(DiscogsConfiguration(userAgent: "x").requestsPerMinute, 22)
        XCTAssertEqual(DiscogsConfiguration(token: "abc", userAgent: "x").requestsPerMinute, 55)
        XCTAssertEqual(DiscogsConfiguration(token: "   ", userAgent: "x").requestsPerMinute, 22,
                       "Leerer Token ist kein Token")
    }

    func test_unauthorized_throws() async {
        let responder = StubResponder()
        responder.route("releases/1", status: 401, json: #"{"message":"nope"}"#)
        let client = makeClient(responder: responder)

        do {
            _ = try await client.release(id: 1)
            XCTFail("401 muss werfen")
        } catch let error as DiscogsError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Falscher Fehlertyp: \(error)")
        }
    }

    func test_serverError_throwsWithStatus() async {
        let responder = StubResponder()
        responder.route("releases/1", status: 502, json: "{}")
        let client = makeClient(responder: responder)

        do {
            _ = try await client.release(id: 1)
            XCTFail("502 muss werfen")
        } catch let error as DiscogsError {
            XCTAssertEqual(error, .server(502))
        } catch {
            XCTFail("Falscher Fehlertyp: \(error)")
        }
    }

    func test_cacheHit_avoidsSecondRequest() async throws {
        let responder = StubResponder()
        responder.route("releases/1", json: releaseJSON)
        let cache = MemoryCache()
        let client = makeClient(responder: responder, cache: cache)

        _ = try await client.release(id: 1)
        _ = try await client.release(id: 1)

        XCTAssertEqual(responder.requestCount, 1, "Zweiter Aufruf kommt aus dem Cache")
        let counters = await cache.counters()
        XCTAssertEqual(counters.writes, 1)
        XCTAssertEqual(counters.hits, 1)
    }

    func test_trackDurationParsing() {
        XCTAssertEqual(makeEntry(duration: "4:45").durationSeconds, 285)
        XCTAssertEqual(makeEntry(duration: "1:02:03").durationSeconds, 3723)
        XCTAssertNil(makeEntry(duration: "").durationSeconds)
        XCTAssertNil(makeEntry(duration: nil).durationSeconds)
    }

    func test_artistJoining() throws {
        let json = """
        {"id":5,"title":"Split","tracklist":[{"position":"A","title":"Track","duration":"5:00"}],
         "artists":[{"name":"Sabre (2)","anv":"","join":"&"},{"name":"Stray","anv":"","join":""}]}
        """
        let release = try JSONDecoder().decode(Discogs.Release.self, from: Data(json.utf8))
        XCTAssertEqual((release.artists ?? []).joinedName, "Sabre & Stray")
    }

    func test_artistNameVariationWins() throws {
        let json = """
        {"id":5,"title":"X","artists":[{"name":"Burial","anv":"Will Bevan","join":""}],"tracklist":[]}
        """
        let release = try JSONDecoder().decode(Discogs.Release.self, from: Data(json.utf8))
        XCTAssertEqual((release.artists ?? []).joinedName, "Will Bevan")
    }

    private func makeEntry(duration: String?) -> Discogs.TrackEntry {
        let durationJSON = duration.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"position":"A","title":"T","duration":\(durationJSON),"type_":"track"}
        """
        return try! JSONDecoder().decode(Discogs.TrackEntry.self, from: Data(json.utf8))
    }
}
