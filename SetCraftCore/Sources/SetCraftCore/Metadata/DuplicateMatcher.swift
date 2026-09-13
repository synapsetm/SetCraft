import Foundation

/// Findet zu einer untagged Datei einen **getaggten Zwilling** in derselben
/// Bibliothek.
///
/// Derselbe Track liegt in gewachsenen Sammlungen oft mehrfach herum — einmal
/// sauber getaggt im Album-Ordner, einmal roh im Download-Ordner. Dieser
/// Abgleich ist die verlässlichste Offline-Quelle überhaupt, weil die Tags von
/// einer Datei kommen, die der Nutzer selbst schon kuratiert hat.
///
/// Gematcht wird über die Spieldauer (aus `AudioProperties`, kostet also
/// nichts) und bestätigt über Dateigrösse oder Namensähnlichkeit. Reine
/// Dauer-Gleichheit reicht nicht: bei 4-Minuten-Tracks kollidiert das ständig.
public struct DuplicateMatcher: Sendable {

    /// Toleranz der Dauer in Sekunden. Dieselbe Aufnahme in MP3 und FLAC
    /// unterscheidet sich durch Encoder-Padding um Bruchteile; ein Edit
    /// unterscheidet sich um mehr als das.
    public static let durationTolerance: TimeInterval = 2.0

    /// Ab dieser Namensähnlichkeit gilt ein Dauer-Treffer als bestätigt.
    public static let nameThreshold = 0.8

    public struct Match: Sendable {
        public let track: Track
        public let confidence: Double
        /// Warum es ein Treffer ist — landet als Notiz im Review-Sheet.
        public let reason: Reason

        public enum Reason: String, Sendable {
            /// Gleiche Dauer **und** gleiche Dateigrösse: praktisch dieselbe Datei.
            case identicalFile
            /// Gleiche Dauer, ähnlicher Name.
            case durationAndName
        }
    }

    /// Kandidaten, gebucketet auf ganze Sekunden.
    private let buckets: [Int: [Track]]

    /// Wie viele Tracks überhaupt als Zwilling in Frage kommen. Steht im
    /// Review-Sheet — wenn hier 0 steht, ist die Bibliothek noch nicht
    /// gescannt, und die Stufe kann gar nichts finden.
    public let candidateCount: Int

    /// Nimmt nur Tracks als Kandidaten auf, die Artist **und** Titel tragen —
    /// alles andere kann nichts beitragen.
    public init(tracks: [Track]) {
        var buckets: [Int: [Track]] = [:]
        for track in tracks where !track.title.isEmpty && !track.artist.isEmpty {
            guard track.durationSeconds > 0 else { continue }
            buckets[Int(track.durationSeconds.rounded()), default: []].append(track)
        }
        self.buckets = buckets
        self.candidateCount = buckets.values.reduce(0) { $0 + $1.count }
    }

    public func match(for track: Track) -> Match? {
        guard track.durationSeconds > 0 else { return nil }
        let key = Int(track.durationSeconds.rounded())
        let tolerance = Int(Self.durationTolerance.rounded())

        var best: Match?
        for offset in -tolerance...tolerance {
            for candidate in buckets[key + offset] ?? [] {
                guard candidate.url != track.url,
                      abs(candidate.durationSeconds - track.durationSeconds) <= Self.durationTolerance
                else { continue }

                guard let match = score(track: track, candidate: candidate) else { continue }
                if best == nil || match.confidence > best!.confidence {
                    best = match
                }
            }
        }
        return best
    }

    private func score(track: Track, candidate: Track) -> Match? {
        if let lhs = track.fileSize, let rhs = candidate.fileSize, lhs == rhs, lhs > 0 {
            return Match(track: candidate, confidence: 0.95, reason: .identicalFile)
        }

        // Verglichen wird der **geparste** Name, nicht der rohe Dateiname:
        // `Oliver_Heldens_Will_Clarke_-_Lost_In_Music_Extended_Mix_-_4DJSONLINE_
        // (SkySound7.com)` hat mit „Oliver Heldens, Will Clarke — Lost In Music"
        // auf Zeichenebene wenig gemein, meint aber dasselbe. Artist und Titel
        // werden getrennt bewertet, und die Mix-Klammer fliegt raus: derselbe
        // Track kann in einer Datei als „(Extended Mix)" ausgewiesen sein und
        // in der anderen nicht.
        let ours = identity(of: track)
        let theirs = identity(of: candidate)
        guard !ours.title.isEmpty, !theirs.title.isEmpty else { return nil }

        let titleScore = TextSimilarity.similarity(ours.title, theirs.title)
        let similarity: Double
        if ours.artist.isEmpty || theirs.artist.isEmpty {
            similarity = titleScore
        } else {
            similarity = titleScore * 0.5 + TextSimilarity.similarity(ours.artist, theirs.artist) * 0.5
        }
        guard similarity >= Self.nameThreshold else { return nil }

        return Match(
            track: candidate,
            confidence: min(0.92, 0.7 + similarity * 0.2),
            reason: .durationAndName
        )
    }

    /// Artist und Titel eines Tracks — aus den Tags, wo vorhanden, sonst aus
    /// dem Dateinamen. Die Mix-Klammer bleibt aussen vor.
    private func identity(of track: Track) -> (artist: String, title: String) {
        if !track.title.isEmpty {
            return (track.artist, FilenameParser.withoutTrailingBracket(track.title))
        }
        let parsed = FilenameParser.parse(url: track.url)
        return (
            track.artist.isEmpty ? parsed.artist : track.artist,
            FilenameParser.withoutTrailingBracket(parsed.title)
        )
    }
}
