import Foundation
import OSLog

/// Discogs als vierte Stufe der Vorschlagskette.
///
/// Ablauf pro Track — und damit die Kosten: Discogs sucht auf **Release**-Ebene
/// und liefert Artist/Titel nur zusammengeklebt. Die Tracklist und die saubere
/// Trennung gibt es erst über `GET /releases/{id}`. Also:
///
/// 1. `database/search` mit Artist + Track (oder Freitext).
/// 2. Die Treffer anhand ihres zusammengeklebten Titels vorsortieren — das
///    kostet nichts und spart Requests.
/// 3. Nur die besten auflösen (Default: zwei) und in deren Tracklist den
///    passenden Eintrag suchen.
///
/// Der Dauer-Abgleich ist der wichtigste Schutz: ohne ihn landet der Radio Edit
/// als Extended Mix in den Tags. Discogs füllt `duration` aber nicht immer —
/// fehlt sie, kann dieser Schutz nicht greifen, und der Vorschlag bleibt im
/// Review-Sheet entsprechend niedriger bewertet.
public struct DiscogsResolver: CatalogLookup {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "DiscogsResolver")

    private let client: DiscogsClient
    /// Wie viele Suchtreffer aufgelöst werden (ein Request pro Stück).
    private let releaseFetchLimit: Int
    /// Ab dieser Punktzahl brechen wir die Suche ab — besser wird es nicht.
    private let goodEnoughScore: Double

    public init(client: DiscogsClient, releaseFetchLimit: Int = 2, goodEnoughScore: Double = 0.9) {
        self.client = client
        self.releaseFetchLimit = releaseFetchLimit
        self.goodEnoughScore = goodEnoughScore
    }

    public func search(_ query: CatalogQuery) async throws -> [CatalogMatch] {
        guard query.isUsable else { return [] }

        var results = try await client.searchReleases(
            artist: query.artist,
            title: query.title,
            catalogNumber: query.catalogNumber
        )
        // Katalognummern aus Dateinamen sind oft verstümmelt („SK032A" statt
        // „SK032"). Ein Fehlschlag damit heisst nicht, dass es den Track nicht
        // gibt — einmal ohne nachfragen.
        if results.isEmpty, !query.catalogNumber.isEmpty {
            results = try await client.searchReleases(artist: query.artist, title: query.title)
        }

        // Zweiter Anlauf ohne Artist. Download-Seiten ersetzen Sonderzeichen im
        // Dateinamen durch Underscores — aus „Ikøn" wird „IK N", und die
        // Feldsuche findet damit nichts. Über den Titel allein steht die
        // Aufnahme trotzdem da; welcher der vielen Gleichnamigen gemeint ist,
        // entscheidet dann das Scoring, das den Artist weiterhin kennt.
        // Weil hier die Trefferliste viel breiter ist, gilt eine strengere
        // Mindestpunktzahl.
        var usedBroadSearch = false
        if results.isEmpty, !query.artist.isEmpty {
            results = try await client.searchReleases(artist: "", title: query.title)
            usedBroadSearch = true
        }
        guard !results.isEmpty else { return [] }

        let ranked = prerank(results, query: query)
        var matches: [CatalogMatch] = []

        for result in ranked.prefix(releaseFetchLimit) {
            let release: Discogs.Release
            do {
                release = try await client.release(id: result.id)
            } catch DiscogsError.notFound {
                continue
            }
            guard let match = bestMatch(in: release, query: query) else { continue }
            matches.append(match)
            if match.score >= goodEnoughScore { break }
        }

        let floor = usedBroadSearch ? Self.broadSearchMinimumScore : 0
        return matches
            .filter { $0.score >= floor }
            .sorted { $0.score > $1.score }
    }

    /// Mindestpunktzahl für Treffer aus der Suche ohne Artist. Deutlich über
    /// der normalen Schwelle: bei einem verbreiteten Titel stünden dort sonst
    /// beliebige gleichnamige Aufnahmen.
    static let broadSearchMinimumScore = 0.75

    // MARK: - Vorsortieren

    /// Sortiert die Suchtreffer ohne weiteren Request: der zusammengeklebte
    /// `title` („The Persuader - Stockholm") reicht für eine grobe Rangfolge.
    /// Vinyl-Pressungen bekommen einen kleinen Bonus, weil DJ-Dateien
    /// typischerweise von dort stammen und Vinyl-Releases die Mix-Fassungen
    /// tragen.
    func prerank(_ results: [Discogs.SearchResult], query: CatalogQuery) -> [Discogs.SearchResult] {
        let needle = [query.artist, query.title].filter { !$0.isEmpty }.joined(separator: " ")
        return results.sorted { lhs, rhs in
            preScore(lhs, needle: needle, query: query) > preScore(rhs, needle: needle, query: query)
        }
    }

    private func preScore(_ result: Discogs.SearchResult, needle: String, query: CatalogQuery) -> Double {
        var score = TextSimilarity.similarity(result.title ?? "", needle)
        let formats = (result.format ?? []).map { $0.lowercased() }
        if formats.contains(where: { $0.contains("vinyl") || $0.contains("12") }) {
            score += 0.05
        }
        if !query.catalogNumber.isEmpty,
           let catno = result.catno,
           TextSimilarity.normalize(catno) == TextSimilarity.normalize(query.catalogNumber) {
            score += 0.15
        }
        if let year = query.year, let resultYear = result.year.flatMap(Int.init), year == resultYear {
            score += 0.03
        }
        return score
    }

    // MARK: - Tracklist auswerten

    /// Sucht in der Tracklist den Eintrag, der am besten zur Anfrage passt.
    /// Überschriften und Index-Einträge fallen raus.
    func bestMatch(in release: Discogs.Release, query: CatalogQuery) -> CatalogMatch? {
        let entries = (release.tracklist ?? []).filter { $0.isPlayableTrack }
        guard !entries.isEmpty else { return nil }

        var best: CatalogMatch?
        for entry in entries {
            guard let rawTitle = entry.title, !rawTitle.isEmpty else { continue }
            let candidate = match(entry: entry, rawTitle: rawTitle, release: release, query: query)
            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }
        return best
    }

    private func match(
        entry: Discogs.TrackEntry,
        rawTitle: String,
        release: Discogs.Release,
        query: CatalogQuery
    ) -> CatalogMatch {
        let bareTitle = FilenameParser.withoutTrailingBracket(rawTitle)
        let entryMix = FilenameParser.mixVersion(in: rawTitle) ?? ""

        // Track-eigene Artists gewinnen (Compilations!), sonst die des Releases.
        let releaseArtist = (release.artists ?? []).joinedName
        let trackArtist = (entry.artists ?? []).joinedName
        let artist = trackArtist.isEmpty ? releaseArtist : trackArtist

        var score = TextSimilarity.similarity(bareTitle, query.title)
        if !query.artist.isEmpty {
            // Titel wiegt schwerer: ein Dateiname kann den Artist weglassen
            // oder als Label-Namen missverstehen, der Titel steht fast immer da.
            score = score * 0.6 + TextSimilarity.similarity(artist, query.artist) * 0.4
        }

        // Dauer: der wichtigste Gegencheck, wo Discogs ihn liefert.
        if let catalogDuration = entry.durationSeconds, query.durationSeconds > 0 {
            let delta = abs(catalogDuration - query.durationSeconds)
            if delta <= 5 {
                score += 0.12
            } else if delta > 20 {
                score -= 0.25
            }
        }

        // Mix-Version: gleiche Fassung bestätigt, eine andere warnt.
        if !query.mixVersion.isEmpty {
            if entryMix.isEmpty {
                score -= 0.05
            } else if TextSimilarity.similarity(entryMix, query.mixVersion) >= 0.7 {
                score += 0.08
            } else {
                score -= 0.12
            }
        }

        let label = (release.labels ?? []).first
        if !query.catalogNumber.isEmpty,
           let catno = label?.catno,
           TextSimilarity.normalize(catno) == TextSimilarity.normalize(query.catalogNumber) {
            score += 0.1
        }

        let position = entry.position?.isEmpty == false ? entry.position! : bareTitle
        return CatalogMatch(
            artist: artist,
            title: rawTitle,
            mixVersion: entryMix,
            album: release.title ?? "",
            label: Discogs.stripDisambiguation(label?.name ?? ""),
            catalogNumber: label?.catno ?? "",
            year: (release.year ?? 0) > 0 ? release.year : nil,
            durationSeconds: entry.durationSeconds,
            score: min(1.0, max(0.0, score)),
            reference: "discogs:release/\(release.id)#\(position)"
        )
    }
}
