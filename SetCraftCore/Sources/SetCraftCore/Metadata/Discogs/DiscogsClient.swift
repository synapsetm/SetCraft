import Foundation
import OSLog

/// Zugangsdaten und Drosselung für api.discogs.com.
public struct DiscogsConfiguration: Sendable {

    /// Personal Access Token aus discogs.com/settings/developers. Optional:
    /// Lesen inklusive Suche funktioniert auch ohne Account, dann aber mit
    /// 25 statt 60 Anfragen pro Minute und ohne Cover-URLs.
    public var token: String?

    /// **Pflicht** und muss die App eindeutig benennen. Generische User-Agents
    /// (curl, leeres Feld) drosselt Discogs härter, und zwar ohne dass es in
    /// den Rate-Limit-Headern sichtbar wird.
    public var userAgent: String

    public var baseURL: URL

    /// Wie lange eine gecachte Antwort gilt. Katalogdaten ändern sich selten;
    /// ein Monat spart bei wiederholten Läufen fast das gesamte Budget.
    public var cacheMaxAge: TimeInterval

    /// Wie viele Suchtreffer wir überhaupt betrachten.
    public var searchResultLimit: Int

    /// Wie viele davon wir auflösen (ein Release-Request pro Stück!). Der
    /// Default ist die Sparvariante: in der Regel reicht der erste Treffer.
    public var releaseFetchLimit: Int

    public init(
        token: String? = nil,
        userAgent: String,
        baseURL: URL = URL(string: "https://api.discogs.com")!,
        cacheMaxAge: TimeInterval = 30 * 24 * 60 * 60,
        searchResultLimit: Int = 10,
        releaseFetchLimit: Int = 2
    ) {
        self.token = token
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.cacheMaxAge = cacheMaxAge
        self.searchResultLimit = searchResultLimit
        self.releaseFetchLimit = releaseFetchLimit
    }

    var hasToken: Bool {
        guard let token else { return false }
        return !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Dokumentiertes Limit ist 60 (mit Token) bzw. 25 (ohne), jeweils pro
    /// Minute und IP. Wir bleiben mit Marge darunter, weil das Fenster auf
    /// Discogs-Seite gleitet und unsere Uhr nicht ihre ist.
    public var requestsPerMinute: Int {
        hasToken ? 55 : 22
    }
}

public enum DiscogsError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case rateLimited
    case notFound
    case server(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Discogs rejected the token."
        case .rateLimited:
            return "Discogs rate limit reached. Try again in a minute."
        case .notFound:
            return "Not found on Discogs."
        case .server(let status):
            return "Discogs returned HTTP \(status)."
        case .invalidResponse:
            return "Unexpected response from Discogs."
        case .network(let reason):
            return "Could not reach Discogs: \(reason)"
        }
    }
}

/// HTTP-Zugang zu Discogs: baut die Requests, hält das Rate-Limit ein und
/// bedient sich zuerst am Cache.
///
/// Als Actor, weil das Rate-Limit-Fenster geteilter Zustand ist — egal wie
/// viele Tracks parallel Vorschläge bauen, gezählt wird an einer Stelle.
public actor DiscogsClient {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "Discogs")

    private let configuration: DiscogsConfiguration
    private let session: URLSession
    private let cache: CatalogResponseCache?
    private let decoder = JSONDecoder()

    /// Zeitstempel der letzten Requests, gleitendes 60-Sekunden-Fenster.
    private var recentRequests: [Date] = []

    public init(
        configuration: DiscogsConfiguration,
        session: URLSession = .shared,
        cache: CatalogResponseCache? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.cache = cache
    }

    // MARK: - Endpunkte
    //
    // Modul-intern: die Discogs-Modelle sind ein Implementierungsdetail und
    // sollen nicht aus den App-Targets heraus sichtbar sein. Nach draussen
    // führt nur `DiscogsResolver` als `CatalogLookup`.

    /// Release-Suche. Mit bekanntem Artist nutzen wir die Feldsuche
    /// (`artist=`/`track=`), sonst die Freitextsuche (`q=`) — die ist
    /// toleranter, liefert aber unschärfere Treffer.
    func searchReleases(
        artist: String,
        title: String,
        catalogNumber: String = ""
    ) async throws -> [Discogs.SearchResult] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: String(configuration.searchResultLimit))
        ]
        if !catalogNumber.isEmpty {
            // Die Katalognummer ist das stärkste Signal, das ein Dateiname
            // hergeben kann — damit trifft man die richtige Pressung direkt.
            items.append(URLQueryItem(name: "catno", value: catalogNumber))
        }
        if artist.isEmpty {
            items.append(URLQueryItem(name: "q", value: title))
        } else {
            items.append(URLQueryItem(name: "artist", value: artist))
            items.append(URLQueryItem(name: "track", value: title))
        }

        let response: Discogs.SearchResponse = try await get(path: "/database/search", items: items)
        return response.results.filter { $0.type == nil || $0.type == "release" }
    }

    func release(id: Int) async throws -> Discogs.Release {
        try await get(path: "/releases/\(id)", items: [])
    }

    // MARK: - HTTP

    private func get<Value: Decodable>(path: String, items: [URLQueryItem]) async throws -> Value {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else { throw DiscogsError.invalidResponse }

        let key = cacheKey(for: url)
        if let cache, let data = await cache.cachedResponse(forKey: key, maxAge: configuration.cacheMaxAge) {
            if let decoded = try? decoder.decode(Value.self, from: data) {
                Self.log.debug("Discogs cache hit: \(path, privacy: .public)")
                return decoded
            }
        }

        let data = try await perform(url: url, allowRetry: true)
        await cache?.store(data, forKey: key)

        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            Self.log.error("Discogs decode failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw DiscogsError.invalidResponse
        }
    }

    private func perform(url: URL, allowRetry: Bool) async throws -> Data {
        try await reserveSlot()

        var request = URLRequest(url: url)
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if configuration.hasToken, let token = configuration.token {
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscogsError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw DiscogsError.invalidResponse }
        absorbRateLimitHeaders(http)

        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw DiscogsError.unauthorized
        case 404:
            throw DiscogsError.notFound
        case 429:
            guard allowRetry else { throw DiscogsError.rateLimited }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            Self.log.notice("Discogs 429, retrying after \(retryAfter, privacy: .public)s")
            try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 90) * 1_000_000_000))
            return try await perform(url: url, allowRetry: false)
        default:
            throw DiscogsError.server(http.statusCode)
        }
    }

    // MARK: - Drosselung

    /// Wartet, bis im gleitenden Minutenfenster ein Platz frei ist, und belegt
    /// ihn. Serialisiert absichtlich — lieber langsam als gesperrt.
    private func reserveSlot() async throws {
        while true {
            let now = Date()
            recentRequests.removeAll { now.timeIntervalSince($0) >= 60 }
            if recentRequests.count < configuration.requestsPerMinute {
                recentRequests.append(now)
                return
            }
            guard let oldest = recentRequests.first else { return }
            let wait = min(max(60 - now.timeIntervalSince(oldest), 0.25), 65)
            Self.log.debug("Discogs rate window full, waiting \(wait, privacy: .public)s")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Discogs schickt den Verbrauch mit. Wenn das Kontingent fast leer ist,
    /// füllen wir unser eigenes Fenster auf — ihre Zählung gilt, nicht unsere.
    private func absorbRateLimitHeaders(_ response: HTTPURLResponse) {
        guard let remainingRaw = response.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining"),
              let remaining = Int(remainingRaw) else { return }
        guard remaining <= 2 else { return }

        let deficit = configuration.requestsPerMinute - recentRequests.count
        if deficit > 0 {
            Self.log.notice("Discogs quota nearly exhausted (remaining \(remaining, privacy: .public)), throttling")
            recentRequests.append(contentsOf: Array(repeating: Date(), count: deficit))
        }
    }

    private func cacheKey(for url: URL) -> String {
        "discogs:" + (url.absoluteString.removingPercentEncoding ?? url.absoluteString)
    }
}
