import Foundation

/// Verdrahtet die Metadaten-Kette für einen Lauf über viele Tracks.
///
/// Enthält bewusst keinen UI-Zustand: beide Plattformen haben eigene
/// ViewModels, teilen sich aber diese Mechanik. Der Runner baut Client,
/// Resolver und Kontext, streamt die Vorschläge und sagt vorher, wie viele
/// Katalog-Requests zu erwarten sind — damit die UI die Wartezeit ankündigen
/// kann, statt den Nutzer minutenlang raten zu lassen.
public struct MetadataFixRunner: Sendable {

    public struct Settings: Sendable {
        /// Welche Felder vorgeschlagen werden dürfen.
        public var fields: Set<MetadataField>
        public var policy: CatalogCheckPolicy
        /// Discogs Personal Access Token. Leer = ohne Account arbeiten
        /// (25 statt 60 Anfragen pro Minute).
        public var discogsToken: String?
        /// Pflichtangabe für Discogs, muss die App eindeutig benennen.
        public var userAgent: String

        public init(
            fields: Set<MetadataField> = MetadataField.all,
            policy: CatalogCheckPolicy = .whenUncertain,
            discogsToken: String? = nil,
            userAgent: String
        ) {
            self.fields = fields
            self.policy = policy
            self.discogsToken = discogsToken
            self.userAgent = userAgent
        }

        var hasToken: Bool {
            guard let discogsToken else { return false }
            return !discogsToken.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Anfragen pro Minute, die Discogs uns zugesteht.
        public var requestsPerMinute: Int {
            DiscogsConfiguration(token: discogsToken, userAgent: userAgent).requestsPerMinute
        }
    }

    private let settings: Settings
    private let resolver: MetadataResolver

    public init(settings: Settings, cache: CatalogResponseCache? = nil) {
        self.settings = settings

        let catalog: CatalogLookup?
        if settings.policy == .off {
            catalog = nil
        } else {
            let client = DiscogsClient(
                configuration: DiscogsConfiguration(
                    token: settings.discogsToken,
                    userAgent: settings.userAgent
                ),
                cache: cache
            )
            catalog = DiscogsResolver(client: client)
        }

        self.resolver = MetadataResolver(
            catalog: catalog,
            options: .init(fields: settings.fields, policy: settings.policy)
        )
    }

    /// Baut den Kontext für einen Lauf. `library` darf alle bekannten Tracks
    /// enthalten — der Zwillings-Abgleich sucht ordnerübergreifend.
    public func context(folderTracks: [Track], library: [Track]) -> MetadataContext {
        MetadataContext.build(folderTracks: folderTracks, library: library)
    }

    public func proposals(for tracks: [Track], context: MetadataContext) -> AsyncStream<MetadataProposal> {
        resolver.proposals(for: tracks, context: context)
    }

    /// Grobe Schätzung der Laufzeit in Sekunden, allein aus dem Rate-Limit.
    ///
    /// Zwei Requests pro Katalog-Abfrage (Suche + Release). Bei `.always` ist
    /// jeder Track betroffen, bei `.whenUncertain` lässt sich das vorher nicht
    /// wissen — dann rechnen wir mit der Hälfte und sagen das der UI als
    /// Schätzung. Cache-Treffer machen es schneller, nie langsamer.
    public func estimatedSeconds(trackCount: Int) -> Double {
        guard settings.policy != .off, trackCount > 0 else { return 0 }
        let affected: Double
        switch settings.policy {
        case .off:           affected = 0
        case .always:        affected = Double(trackCount)
        case .whenUncertain: affected = Double(trackCount) * 0.5
        }
        let requests = affected * 2
        return requests / Double(settings.requestsPerMinute) * 60
    }
}
