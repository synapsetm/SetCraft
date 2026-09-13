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

    /// Nimmt nur Tracks als Kandidaten auf, die Artist **und** Titel tragen —
    /// alles andere kann nichts beitragen.
    public init(tracks: [Track]) {
        var buckets: [Int: [Track]] = [:]
        for track in tracks where !track.title.isEmpty && !track.artist.isEmpty {
            guard track.durationSeconds > 0 else { continue }
            buckets[Int(track.durationSeconds.rounded()), default: []].append(track)
        }
        self.buckets = buckets
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

        // Namensvergleich gegen die Tags des Kandidaten, nicht gegen dessen
        // Dateinamen — der kann genauso kryptisch sein wie unserer.
        let stem = track.url.deletingPathExtension().lastPathComponent
        let tagged = "\(candidate.artist) \(candidate.title)"
        let similarity = TextSimilarity.similarity(stem, tagged)
        guard similarity >= Self.nameThreshold else { return nil }

        return Match(
            track: candidate,
            confidence: min(0.92, 0.7 + similarity * 0.2),
            reason: .durationAndName
        )
    }
}
