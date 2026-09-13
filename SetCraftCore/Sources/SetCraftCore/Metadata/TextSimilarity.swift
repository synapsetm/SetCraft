import Foundation

/// Normalisierung und Ähnlichkeitsmass für Tag-Texte.
///
/// Wird von allen Metadaten-Providern geteilt: der `PatternLearner` vergleicht
/// damit Tag-Werte gegen Dateinamen-Bruchstücke, der `DiscogsResolver` bewertet
/// damit Katalog-Treffer gegen den geparsten Dateinamen. Weil daran
/// Auto-Übernahme-Schwellen hängen, liegt das Mass an **einer** Stelle.
public enum TextSimilarity {

    /// Vergleichsform eines Strings: klein, ohne Diakritika, ohne Satzzeichen,
    /// Whitespace zusammengefasst. Führendes „the" fällt weg, weil Discogs
    /// „The Persuader" und Tags „Persuader" munter mischen.
    public static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        var result = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if result.hasPrefix("the ") { result.removeFirst(4) }
        return result
    }

    public static func tokens(_ raw: String) -> [String] {
        normalize(raw).split(separator: " ").map(String.init)
    }

    /// 0…1. Kombiniert zwei Sichtweisen, weil beide eigene Blindstellen haben:
    /// Levenshtein über die sortierten Tokens fängt Tippfehler und fehlende
    /// Buchstaben, die Token-Schnittmenge fängt umgestellte Wortfolgen und
    /// Zusätze. Genommen wird der bessere der beiden Werte.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let tokensA = tokens(a)
        let tokensB = tokens(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else {
            return tokensA.isEmpty && tokensB.isEmpty ? 1.0 : 0.0
        }

        let sortedA = tokensA.sorted().joined(separator: " ")
        let sortedB = tokensB.sorted().joined(separator: " ")
        return max(levenshteinRatio(sortedA, sortedB), tokenSetRatio(tokensA, tokensB))
    }

    /// Anteil gemeinsamer Tokens an der Vereinigung (Jaccard). Robust gegen
    /// „Artist feat. X" vs. „Artist", schwach bei Tippfehlern.
    public static func tokenSetRatio(_ a: [String], _ b: [String]) -> Double {
        let setA = Set(a)
        let setB = Set(b)
        guard !setA.isEmpty || !setB.isEmpty else { return 1.0 }
        let union = setA.union(setB).count
        guard union > 0 else { return 1.0 }
        return Double(setA.intersection(setB).count) / Double(union)
    }

    /// 1 − (Editierdistanz / Länge des längeren Strings).
    public static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let maxLength = max(a.count, b.count)
        guard maxLength > 0 else { return 1.0 }
        let distance = levenshtein(Array(a), Array(b))
        return max(0, 1.0 - Double(distance) / Double(maxLength))
    }

    /// Zeilenweises DP, nur zwei Zeilen im Speicher.
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // Löschen
                    current[j - 1] + 1,     // Einfügen
                    previous[j - 1] + cost  // Ersetzen
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
