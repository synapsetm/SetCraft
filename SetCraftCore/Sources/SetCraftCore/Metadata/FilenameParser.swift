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
        "outro", "transition", "dubplate"
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
        // Underscores zuerst: enthaelt der Name ueberhaupt kein Leerzeichen,
        // sind sie die Wortgrenze. Das muss VOR allem anderen passieren —
        // sonst macht `_-_` den Namen leerzeichenhaltig und die restlichen
        // Underscores bleiben mitten im Titel stehen
        // (`Seratonin_Extended_Mix - 4DJSONLINE`).
        var working = rawStem.contains(" ")
            ? rawStem
            : rawStem.replacingOccurrences(of: "_", with: " ")

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
        working = stripTrailingSiteTag(working)
        working = collapseWhitespace(working)
        result.cleanedStem = working

        let split = splitArtistTitle(working)
        result.hasSeparator = split.found
        result.separatorWasWeak = split.weak

        // Erst die Mix-Bezeichnung einklammern, dann die Reihenfolge klären:
        // sonst bleibt „Higher Dimension Original Mix" ohne Klammer und
        // verrät nicht, dass es die Titel-Seite ist.
        var left = bracketMixVersion(in: split.left)
        var right = bracketMixVersion(in: split.right)

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
        let normalized = input
            .replacingOccurrences(of: "_-_", with: " - ")
            .replacingOccurrences(of: " – ", with: " - ")   // En-Dash
            .replacingOccurrences(of: " — ", with: " - ")   // Em-Dash
            .replacingOccurrences(of: " -- ", with: " - ")

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
    /// Entfernt ein angehaengtes Seiten-/Release-Kuerzel als **drittes** Feld
    /// (`Artist - Title - 4DJSONLINE`).
    ///
    /// Die Bedingung „drittes Feld" ist der Schutz: bei nur einem Trenner ist
    /// die rechte Seite der Titel und darf nie verschwinden — sonst frisst die
    /// Regel `Song - AMEN`. Zusaetzlich muss das Kuerzel ein einzelnes Token
    /// ohne Kleinbuchstaben sein, wie Download-Seiten und Scene-Gruppen es
    /// schreiben.
    static func stripTrailingSiteTag(_ input: String) -> String {
        let separators = input.components(separatedBy: " - ").count - 1
        guard separators >= 2 else { return input }
        guard let match = input.range(
            of: #"\s+-\s+[A-Z0-9][A-Z0-9._+-]{3,19}\s*$"#,
            options: .regularExpression
        ) else { return input }

        let token = input[match].trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        // Kurze Grossbuchstaben-Woerter sind oft Teil des Titels („Song - AMEN").
        // Als Seiten-/Scene-Kuerzel gelten nur lange Token oder solche mit
        // Ziffer — so wie „4DJSONLINE", „ZIPPYSHARE", „MYFREEMP3".
        let looksLikeTag = token.count >= 6 || (token.count >= 4 && token.contains(where: \.isNumber))
        guard looksLikeTag else { return input }
        return String(input[..<match.lowerBound])
    }

    /// Woerter, die zu einer Mix-Bezeichnung gehoeren, ohne selbst das
    /// Schlagwort zu sein („Original Mix", „Extended Mix", „Radio Edit").
    static let mixQualifiers: Set<String> = [
        "original", "extended", "radio", "club", "vocal", "dub", "long",
        "short", "full", "main", "album", "single", "alternative", "alternate",
        "live", "remastered", "remaster", "special", "dirty", "clean", "deep",
        "festival", "private", "bonus", "instrumental", "acapella", "acappella",
        "vip", "edit", "mix", "re"
    ]

    /// Schlagwoerter, vor denen ueblicherweise ein **Remixer-Name** steht.
    /// „Dub", „Version" oder „Live" gehoeren bewusst nicht dazu: sie sind
    /// genauso oft Teil des Titels („Anti War Dub"), und ein falsch
    /// abgetrennter Titel ist schlimmer als eine fehlende Klammer.
    private static let remixerKeywords: Set<String> = [
        "remix", "rmx", "mix", "edit", "reedit", "bootleg", "rework",
        "refix", "remake", "flip", "mashup", "vip"
    ]

    /// Verbinder in Remixer-Namen („Dense & Pika Remix").
    private static let artistConnectors: Set<String> = ["&", "and", "vs", "vs.", "x", "ft", "ft.", "feat", "feat."]

    /// Bezeichnungen, die auch allein in Klammern gehoeren.
    private static let standaloneMixWords: Set<String> = ["instrumental", "acapella", "acappella"]

    /// Setzt eine Mix-Bezeichnung am Titelende in Klammern, falls sie dort
    /// nackt steht: `Higher Dimension Original MIx` → `Higher Dimension
    /// (Original Mix)`. Fuer DJ-Software ist das der Unterschied zwischen
    /// „zwei Fassungen desselben Tracks" und „zwei zufaellig aehnliche Titel".
    ///
    /// Das Schlagwort wird dabei in seine uebliche Schreibweise gebracht
    /// (`MIx` → `Mix`, `rmx` → `Rmx`); Namen bleiben, wie sie sind.
    static func bracketMixVersion(in title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return title }
        // Schon geklammert? Dann ist nichts zu tun.
        if mixVersion(in: trimmed) != nil { return trimmed }
        // Endet der Titel ueberhaupt auf einer Klammer, lassen wir ihn in Ruhe.
        if trimmed.hasSuffix(")") || trimmed.hasSuffix("]") { return trimmed }

        var words = trimmed.split(separator: " ").map(String.init)
        guard let last = words.last,
              mixKeywords.contains(bareWord(last)) else { return trimmed }

        var phrase = [words.removeLast()]

        // Qualifier davor einsammeln („Extended", „Original", „Radio").
        while let previous = words.last, mixQualifiers.contains(bareWord(previous)) {
            phrase.insert(words.removeLast(), at: 0)
        }

        // Kein Qualifier? Dann steht dort typischerweise der Remixer-Name.
        // Genau ein Wort nehmen — und bei einem Verbinder die beiden davor
        // dazu, damit „Dense & Pika Remix" nicht in der Mitte zerfaellt.
        if phrase.count == 1, words.count >= 2, remixerKeywords.contains(bareWord(phrase[0])) {
            phrase.insert(words.removeLast(), at: 0)
            // Roh vergleichen, nicht über `bareWord`: das würde „&" auf einen
            // leeren String eindampfen.
            let previous = words[words.count - 1].lowercased()
            if words.count >= 2, artistConnectors.contains(previous) {
                phrase.insert(words.removeLast(), at: 0)
                phrase.insert(words.removeLast(), at: 0)
            }
        }

        let isStandalone = phrase.count == 1 && standaloneMixWords.contains(bareWord(phrase[0]))
        guard !words.isEmpty, phrase.count >= 2 || isStandalone else { return trimmed }

        let normalizedPhrase = phrase.map(normalizeMixWord).joined(separator: " ")
        return words.joined(separator: " ") + " (" + normalizedPhrase + ")"
    }

    /// Schreibweise eines bekannten Mix-Worts vereinheitlichen; alles andere
    /// (Remixer-Namen) bleibt unangetastet.
    private static func normalizeMixWord(_ word: String) -> String {
        let bare = bareWord(word)
        guard mixKeywords.contains(bare) || mixQualifiers.contains(bare) else { return word }
        return bare.prefix(1).uppercased() + bare.dropFirst()
    }

    private static func bareWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Titel ohne abschliessende Klammer. Fuer Katalog-Suchen: eine Fassung
    /// mit (Extended Mix) findet sich dort unter dem nackten Titel.
    public static func withoutTrailingBracket(_ title: String) -> String {
        let stripped = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }

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
