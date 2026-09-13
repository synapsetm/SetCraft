import Foundation

/// Zerlegt einen Dateinamen in Artist, Titel und Mix-Version.
///
/// Reihenfolge der Schritte (jeder arbeitet auf dem Ergebnis des vorigen):
/// 1. Endung weg, Rip-/Scene-Reste entfernen (Seiten-URLs, `[320kbps]`, `[WEB]`).
/// 2. Jahr aus Klammern ziehen (`(1999)`).
/// 3. Tracknummer bzw. Vinyl-Position am Anfang abschneiden (`03 - `, `B2 - `).
/// 4. Katalognummer am Anfang abschneiden (`SK032 - `).
/// 5. Trenner normalisieren (En-Dash, `_-_`, Underscores) und splitten.
/// 6. Mix-Klammer und „feat." isolieren — beide bleiben im Titel stehen.
///
/// Bewusste Grenze: Die Reihenfolge „Artist - Title" vs. „Title - Artist"
/// lässt sich aus dem Namen allein nicht entscheiden. Liegt kein Signal vor
/// (Mix-Klammer auf einer Seite), bleibt `orderIsAmbiguous` gesetzt und ein
/// späterer Provider muss es klären.
public enum FilenameParser {

    /// Klammerinhalte, die eine Mix-/Versionsbezeichnung markieren.
    static let mixKeywords: Set<String> = [
        "mix", "remix", "rmx", "edit", "re-edit", "reedit", "dub", "version",
        "bootleg", "vip", "rework", "refix", "remake", "flip", "mashup",
        "instrumental", "acapella", "acappella", "radio", "extended",
        "original", "club", "live", "remaster", "remastered", "intro",
        "outro", "transition", "dubplate", "remix)", "mixes"
    ]

    /// Reste aus Downloads und Rips. Reihenfolge ist relevant: erst die
    /// klammerbehafteten Varianten, dann die nackten.
    private static let noisePatterns: [String] = [
        #"[\[\(]\s*(www\.)?[a-z0-9][a-z0-9-]*\.(com|net|org|ru|me|cc|info|biz|to|io)\s*[^\)\]]*[\]\)]"#,
        #"^\s*(www\.)?[a-z0-9][a-z0-9-]*\.(com|net|org|ru|me|cc|info|biz|to|io)\s*[-_~]+\s*"#,
        #"[\[\(][^\)\]]*\b(\d{2,4}\s?kbps|flac|lossless|v0|v2|320|256|192|128)\b[^\)\]]*[\]\)]"#,
        #"[\[\(]\s*(web|webrip|vinyl|cdq|cdm|cds|cd|hq|promo|single|ep|lp|12inch|12")\s*[\]\)]"#,
        #"\b(hq|cdq)\s*$"#
    ]

    public static func parse(url: URL) -> ParsedFilename {
        parse(stem: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(stem rawStem: String) -> ParsedFilename {
        var result = ParsedFilename()
        var working = rawStem

        for pattern in noisePatterns {
            working = working.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        (working, result.year) = extractYear(working)
        working = collapseWhitespace(working)
        (working, result.trackNumber, result.vinylPosition) = extractLeadingPosition(working)
        (working, result.catalogNumber) = extractCatalogNumber(working)
        working = collapseWhitespace(working)
        result.cleanedStem = working

        let split = splitArtistTitle(working)
        result.hasSeparator = split.found
        result.separatorWasWeak = split.weak

        var left = split.left
        var right = split.right

        // Reihenfolge klären: Die Seite mit der Mix-Klammer ist der Titel.
        if split.found {
            let leftHasMix = mixVersion(in: left) != nil
            let rightHasMix = mixVersion(in: right) != nil
            if leftHasMix && !rightHasMix {
                swap(&left, &right)
                result.orderIsAmbiguous = false
            } else if rightHasMix && !leftHasMix {
                result.orderIsAmbiguous = false
            }
            result.artist = left
            result.title = right
        } else {
            // Kein Trenner: alles ist Titel, Artist bleibt offen.
            result.title = left
            result.orderIsAmbiguous = false
        }

        if let mix = mixVersion(in: result.title) {
            result.mixVersion = mix
        }
        result.featuring = featuredArtist(in: result.title) ?? featuredArtist(in: result.artist) ?? ""

        result.artist = tidy(result.artist)
        result.title = tidy(result.title)
        return result
    }

    // MARK: - Schritte

    private static func extractYear(_ input: String) -> (String, Int?) {
        guard let match = input.range(
            of: #"[\[\(](19\d{2}|20\d{2})[\]\)]"#,
            options: .regularExpression
        ) else { return (input, nil) }

        let digits = input[match].filter(\.isNumber)
        var stripped = input
        stripped.removeSubrange(match)
        return (stripped, Int(digits))
    }

    /// `03 - `, `03. `, `3 ` oder Vinyl-Positionen wie `A1 - `, `B2. `.
    private static func extractLeadingPosition(_ input: String) -> (String, Int?, String) {
        if let match = input.range(
            of: #"^\s*(\d{1,3})\s*[-._)\]]\s*"#,
            options: .regularExpression
        ) {
            let number = Int(input[match].filter(\.isNumber))
            return (String(input[match.upperBound...]), number, "")
        }
        // Nackte Zahl + Leerzeichen nur, wenn danach kein weiterer Zahlenblock
        // kommt — „2 Unlimited - No Limits" darf nicht zur Tracknummer werden,
        // deshalb verlangen wir mindestens zwei Ziffern.
        if let match = input.range(
            of: #"^\s*(\d{2,3})\s+(?![-–])"#,
            options: .regularExpression
        ) {
            let number = Int(input[match].filter(\.isNumber))
            return (String(input[match.upperBound...]), number, "")
        }
        if let match = input.range(
            of: #"^\s*([A-D][1-9]?)\s*[-._)\]]\s+"#,
            options: .regularExpression
        ) {
            let position = input[match].trimmingCharacters(in: CharacterSet(charactersIn: " -._)]"))
            return (String(input[match.upperBound...]), nil, position)
        }
        return (input, nil, "")
    }

    /// Katalognummer am Anfang: Buchstabenblock + Ziffern, gefolgt von einem
    /// Trenner. Ohne Ziffern greifen wir nicht zu — sonst verschwindet
    /// „SBTRKT - Wildfire" in der Katalognummer.
    private static func extractCatalogNumber(_ input: String) -> (String, String) {
        guard let match = input.range(
            of: #"^\s*([A-Z]{2,6}[-_ ]?\d{2,5}[A-Za-z]?)\s*[-_]\s+"#,
            options: .regularExpression
        ) else { return (input, "") }

        let catalog = input[match]
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        return (String(input[match.upperBound...]), catalog)
    }

    private static func splitArtistTitle(_ input: String) -> (left: String, right: String, found: Bool, weak: Bool) {
        var normalized = input
            .replacingOccurrences(of: "_-_", with: " - ")
            .replacingOccurrences(of: " – ", with: " - ")   // En-Dash
            .replacingOccurrences(of: " — ", with: " - ")   // Em-Dash
            .replacingOccurrences(of: " -- ", with: " - ")

        // Nur wenn der Name gar keine Leerzeichen kennt, sind Underscores als
        // Wortgrenze gemeint (`Artist_Name-Track_Title`).
        if !normalized.contains(" ") {
            normalized = normalized.replacingOccurrences(of: "_", with: " ")
        }

        if let range = normalized.range(of: " - ") {
            return (
                String(normalized[..<range.lowerBound]),
                String(normalized[range.upperBound...]),
                true,
                false
            )
        }

        // Schwacher Fall: genau ein nackter Bindestrich zwischen zwei Zeichen.
        let bareHyphens = normalized.regexRanges(of: #"(?<=\S)-(?=\S)"#)
        if bareHyphens.count == 1, let range = bareHyphens.first {
            let left = String(normalized[..<range.lowerBound])
            let right = String(normalized[range.upperBound...])
            if left.count >= 2 && right.count >= 2 {
                return (left, right, true, true)
            }
        }

        return (normalized, "", false, false)
    }

    /// Inhalt der letzten Klammer, wenn er nach Mix-Bezeichnung aussieht.
    static func mixVersion(in text: String) -> String? {
        let brackets = text.regexRanges(of: #"[\(\[][^\)\]]+[\)\]]"#)
        for range in brackets.reversed() {
            let inner = text[range]
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
            let words = inner.lowercased().split(whereSeparator: { !$0.isLetter })
            if words.contains(where: { mixKeywords.contains(String($0)) }) {
                return inner
            }
        }
        return nil
    }

    /// „feat. X", „ft. X", „featuring X" bis zur nächsten Klammer.
    static func featuredArtist(in text: String) -> String? {
        guard let match = text.range(
            of: #"\b(feat\.?|ft\.?|featuring)\s+[^\(\)\[\]]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }

        let raw = String(text[match])
        guard let space = raw.firstIndex(of: " ") else { return nil }
        return String(raw[raw.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static func collapseWhitespace(_ input: String) -> String {
        input.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Schlusskosmetik: Ränder säubern, doppelte Leerzeichen weg, aber
    /// Klammern und Satzzeichen im Inneren unangetastet lassen.
    ///
    /// Underscores werden pro Seite aufgelöst: `Four_Tet_-_Baby` wird beim
    /// Splitten zu `Four_Tet` + `Baby`, die linke Seite hat dann noch immer
    /// kein Leerzeichen und meint mit `_` eine Wortgrenze.
    private static func tidy(_ input: String) -> String {
        var text = input
        if !text.contains(" ") {
            text = text.replacingOccurrences(of: "_", with: " ")
        }
        return collapseWhitespace(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_–—.,"))
    }
}

private extension String {
    /// Alle Treffer eines Regex als Ranges — `range(of:)` liefert nur den ersten.
    func regexRanges(of pattern: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let found = range(of: pattern, options: .regularExpression, range: searchStart..<endIndex) {
            result.append(found)
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : index(after: found.lowerBound)
        }
        return result
    }
}
