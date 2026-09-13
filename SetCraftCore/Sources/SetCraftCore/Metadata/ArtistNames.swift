import Foundation

/// Umgang mit mehreren Interpreten in einem Artist-Tag.
///
/// **Warum ein einziger String?** Die Bridge schreibt über TagLibs
/// `setArtist()` genau ein `TPE1`-Frame. ID3v2.4 könnte mehrere Werte per
/// Null-Byte trennen, aber Serato und Rekordbox zeigen schlicht den String —
/// ein Mehrwert-Frame brächte dort nichts und anderswo Ärger. Der gemeinsame
/// Nenner ist also ein lesbarer String mit lesbarem Trenner.
///
/// **Welcher Trenner?** `, ` — so liefert es Beatport, und so sieht der
/// Grossteil gekaufter DJ-Dateien aus.
///
/// **Wichtig:** normalisiert wird nur dort, wo die Struktur *bekannt* ist —
/// aus Discogs' Artist-Liste oder aus einer Zerlegung anhand bekannter Namen.
/// Ein roher Dateiname wird nie angefasst: „Above & Beyond" und „Simon &
/// Garfunkel" sind je **ein** Interpret, und aus dem String allein ist das
/// nicht zu unterscheiden.
public enum ArtistNames {

    /// Trennzeichen beim Schreiben mehrerer Interpreten.
    public static let separator = ", "

    /// Verbinder, die eine Aufzählung meinen (dürfen durch `separator` ersetzt
    /// werden).
    static let enumerationJoins: Set<String> = ["", ",", "&", "and", "+", "x", "/"]

    /// Zerlegt einen Artist-String in Einzelnamen. Für den Aufbau der
    /// Namensliste und für Vergleiche — **nicht** zum Umschreiben von Tags.
    public static func components(of raw: String) -> [String] {
        let pattern = #"\s*[,;/]\s*|\s+&\s+|\s*\+\s*|\s+(?:and|x|vs\.?|versus|feat\.?|ft\.?|featuring|pres\.?|presents|with|meets)\s+"#
        let parts = raw.replacingOccurrences(
            of: pattern,
            with: "\u{1}",
            options: [.regularExpression, .caseInsensitive]
        ).components(separatedBy: "\u{1}")

        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `true`, wenn der String selbst schon eine Grenze zeigt. Dann ist nichts
    /// zu raten.
    public static func hasExplicitSeparator(_ raw: String) -> Bool {
        components(of: raw).count > 1
    }

    /// Baut aus bekannten Tracks ein Verzeichnis `normalisiert → Schreibweise`.
    /// Quelle sind die Artist-Tags der Bibliothek, in Einzelnamen zerlegt.
    public static func knownNames(from tracks: [Track]) -> [String: String] {
        var map: [String: String] = [:]
        for track in tracks {
            for name in components(of: track.artist) {
                guard name.count >= 2 else { continue }
                let key = TextSimilarity.normalize(name)
                guard !key.isEmpty, map[key] == nil else { continue }
                map[key] = name
            }
        }
        return map
    }

    /// Versucht, einen Artist-String ohne Trennzeichen in mehrere **bekannte**
    /// Namen zu zerlegen.
    ///
    /// Der Fall stammt aus der Praxis: Download-Seiten ersetzen jedes
    /// Sonderzeichen durch einen Underscore, aus „Luca Antolini, Andrea
    /// Montorsi" wird `Luca_Antolini_Andrea_Montorsi` — die Grenze ist im
    /// Dateinamen schlicht weg. Wiederherstellen lässt sie sich nur mit
    /// Wissen von aussen, und das billigste Wissen ist die eigene Bibliothek:
    /// stehen beide Namen dort schon in anderen Dateien, ist die Zerlegung
    /// eindeutig.
    ///
    /// Bedingungen, damit nichts kaputtgeht:
    /// - Ist der **ganze** String selbst ein bekannter Name, wird nie zerlegt
    ///   („Paul van Dyk" bleibt „Paul van Dyk", auch wenn „Paul" bekannt wäre).
    /// - Die Zerlegung muss den String **lückenlos** abdecken.
    /// - Von mehreren möglichen Zerlegungen gewinnt die mit den wenigsten
    ///   Teilen, also den längsten Namen.
    public static func split(_ raw: String, usingKnownNames known: [String: String]) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, known[TextSimilarity.normalize(trimmed)] == nil else { return nil }

        let words = trimmed.split(separator: " ").map(String.init)
        guard words.count >= 2, words.count <= 12 else { return nil }

        // Wortweises Dynamic Programming: `best[i]` ist die kürzeste Zerlegung
        // der ersten i Wörter in bekannte Namen.
        var best: [[String]?] = Array(repeating: nil, count: words.count + 1)
        best[0] = []

        for end in 1...words.count {
            for start in 0..<end {
                guard let prefix = best[start] else { continue }
                let phrase = words[start..<end].joined(separator: " ")
                guard let display = known[TextSimilarity.normalize(phrase)] else { continue }
                let candidate = prefix + [display]
                if best[end] == nil || candidate.count < best[end]!.count {
                    best[end] = candidate
                }
            }
        }

        guard let parts = best[words.count], parts.count >= 2 else { return nil }
        return parts
    }

    /// Setzt eine bekannte Namensliste zum Tag-Wert zusammen.
    public static func join(_ names: [String]) -> String {
        names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}
