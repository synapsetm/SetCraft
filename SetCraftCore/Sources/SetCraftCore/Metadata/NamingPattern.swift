import Foundation

/// Das Namensschema eines Ordners, abgeleitet aus den Dateien, die **schon**
/// saubere Tags haben.
///
/// Der Trick dahinter: In den meisten Sammlungen ist die Mehrheit der Dateien
/// korrekt getaggt. Für die vergleicht man Tag-Werte gegen die Stellen im
/// Dateinamen und weiss danach, ob in diesem Ordner „Artist - Title" oder
/// „Title - Artist" gilt. Das Ergebnis lässt sich auf die untagged Geschwister
/// anwenden — ohne Netz und ohne Raten.
public struct NamingPattern: Sendable, Equatable {

    public enum Layout: String, Sendable {
        /// `Artist - Title`
        case artistFirst
        /// `Title - Artist` — in echten Sammlungen häufiger als man denkt.
        case titleFirst
        /// Kein Trenner, der ganze Name ist der Titel.
        case titleOnly
    }

    public let layout: Layout
    /// Wie viele getaggte Geschwister überhaupt auswertbar waren.
    public let sampleCount: Int
    /// Anteil der auswertbaren Geschwister, die dieses Layout stützen (0…1).
    public let agreement: Double

    public init(layout: Layout, sampleCount: Int, agreement: Double) {
        self.layout = layout
        self.sampleCount = sampleCount
        self.agreement = agreement
    }

    /// Ab wann wir dem Schema trauen. Drei Belege sind das Minimum — bei zwei
    /// Dateien ist „Mehrheit" ein Münzwurf.
    public static let minimumSamples = 3
    public static let minimumAgreement = 0.75

    public var isTrustworthy: Bool {
        sampleCount >= Self.minimumSamples && agreement >= Self.minimumAgreement
    }

    /// Confidence-Beitrag des Schemas: ein einstimmiger Ordner mit vielen
    /// Belegen ist so gut wie ein Katalog-Treffer, ein knapper nicht.
    public var confidence: Double {
        guard isTrustworthy else { return 0 }
        let sampleBonus = min(Double(sampleCount) / 10.0, 1.0) * 0.1
        return min(0.9, 0.6 + agreement * 0.2 + sampleBonus)
    }
}

/// Leitet ein `NamingPattern` aus getaggten Tracks ab.
public enum PatternLearner {

    /// Ab dieser Ähnlichkeit gilt ein Tag-Wert als „steht so im Dateinamen".
    static let matchThreshold = 0.7

    /// Wertet alle Tracks aus, die Artist **und** Titel gesetzt haben, und
    /// stimmt über das Layout ab. Tracks ohne Tags sind die Kundschaft, nicht
    /// die Belege — sie werden übergangen.
    public static func learn(from tracks: [Track]) -> NamingPattern? {
        var votes: [NamingPattern.Layout: Int] = [:]

        for track in tracks {
            guard let vote = vote(for: track) else { continue }
            votes[vote, default: 0] += 1
        }

        let total = votes.values.reduce(0, +)
        guard total > 0, let winner = votes.max(by: { lhs, rhs in
            // Gleichstand deterministisch auflösen, damit dasselbe Verzeichnis
            // nicht zwischen zwei Layouts flackert.
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }) else { return nil }

        return NamingPattern(
            layout: winner.key,
            sampleCount: total,
            agreement: Double(winner.value) / Double(total)
        )
    }

    /// Stimme eines einzelnen getaggten Tracks.
    static func vote(for track: Track) -> NamingPattern.Layout? {
        guard !track.title.isEmpty else { return nil }
        let parsed = FilenameParser.parse(url: track.url)

        guard parsed.hasSeparator, !track.artist.isEmpty else {
            // Ohne Trenner kann der Name nur den Titel tragen. Das ist nur
            // dann ein Beleg, wenn der Titel-Tag auch wirklich dem Namen
            // entspricht — sonst ist die Datei einfach kryptisch benannt.
            guard !parsed.hasSeparator,
                  TextSimilarity.similarity(parsed.title, track.title) >= matchThreshold else {
                return nil
            }
            return .titleOnly
        }

        let artistFirst = (TextSimilarity.similarity(parsed.artist, track.artist)
                           + TextSimilarity.similarity(parsed.title, track.title)) / 2
        let titleFirst = (TextSimilarity.similarity(parsed.artist, track.title)
                          + TextSimilarity.similarity(parsed.title, track.artist)) / 2

        guard max(artistFirst, titleFirst) >= matchThreshold else { return nil }
        // Gleichstand kommt vor, wenn Artist und Titel gleich heissen
        // („Blue Monday - Blue Monday") — daraus lernen wir nichts.
        guard artistFirst != titleFirst else { return nil }
        return artistFirst > titleFirst ? .artistFirst : .titleFirst
    }

    /// Wendet das Schema auf ein Parse-Ergebnis an. Bei `titleFirst` werden
    /// die Seiten getauscht, in beiden Fällen ist die Reihenfolge danach
    /// geklärt.
    public static func apply(_ pattern: NamingPattern, to parsed: ParsedFilename) -> ParsedFilename {
        guard pattern.isTrustworthy, parsed.hasSeparator else { return parsed }
        var result = parsed

        switch pattern.layout {
        case .artistFirst:
            result.orderIsAmbiguous = false
        case .titleFirst:
            swap(&result.artist, &result.title)
            result.orderIsAmbiguous = false
            // Mix-Version hängt am Titel — nach dem Tausch neu bestimmen.
            result.mixVersion = FilenameParser.mixVersion(in: result.title) ?? ""
        case .titleOnly:
            // Der Ordner benennt üblicherweise nur Titel; ein Trenner in
            // diesem Namen ist dann eher Teil des Titels als eine Grenze.
            break
        }
        return result
    }
}
