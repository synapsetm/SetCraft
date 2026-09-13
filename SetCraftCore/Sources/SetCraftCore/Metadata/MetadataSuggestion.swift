import Foundation

/// Tag-Felder, die die Metadaten-Kette ergänzen darf.
///
/// Genre fehlt bewusst: Discogs' `styles` wären verlockend („Deep House" statt
/// „Electronic"), würden aber eine vom Nutzer kuratierte Spalte überschreiben.
/// BPM und Key sind ebenfalls nicht dabei — die kommen aus der Audio-Analyse,
/// nicht aus einem Katalog.
public enum MetadataField: String, Sendable, CaseIterable, Codable {
    case artist
    case title
    case album
    case label
    case year

    /// Ohne diese Felder ergibt die ganze Übung keinen Sinn.
    public static let core: Set<MetadataField> = [.artist, .title]
    public static let all: Set<MetadataField> = Set(allCases)
}

/// Woher ein Vorschlag kommt. Die Reihenfolge entspricht der Stufenfolge der
/// Kette, nicht der Verlässlichkeit.
public enum SuggestionSource: String, Sendable, Codable {
    /// Reines Dateinamen-Parsing.
    case filename
    /// Dateiname, aber mit dem im Ordner gelernten Schema ausgerichtet.
    case folderPattern
    /// Getaggter Zwilling in der eigenen Bibliothek.
    case libraryDuplicate
    /// Katalog-Abgleich (Discogs).
    case catalog
    /// Von Hand im Review-Sheet eingetippt.
    case manual
}

/// Vorschlag für **ein** Feld.
public struct FieldSuggestion: Sendable, Equatable, Identifiable {
    public var field: MetadataField
    /// Vorgeschlagener Wert. `year` steht hier als Dezimalstring.
    public var value: String
    /// Was aktuell in der Datei steht (leer = fehlt).
    public var currentValue: String
    public var source: SuggestionSource
    /// 0…1. Interpretation siehe `SuggestionConfidence`.
    public var confidence: Double
    /// Im Review-Sheet vorausgewählt. Nur dort `true`, wo ein Wert **fehlt**
    /// und die Confidence trägt — bestehende Werte überschreibt niemand
    /// versehentlich.
    public var isAccepted: Bool
    /// Was die anderen Stufen vorgeschlagen hatten, absteigend nach Confidence.
    ///
    /// Wird gebraucht, weil keine Stufe immer recht hat: bei einem Bootleg
    /// kennt Discogs den Remix nicht und „korrigiert" den richtigen
    /// Dateinamen-Titel kaputt. Der verworfene Wert bleibt deshalb erhalten
    /// und ist im Review-Sheet einen Klick entfernt.
    public var alternatives: [Alternative]

    /// Ein verworfener Kandidat.
    public struct Alternative: Sendable, Equatable, Identifiable {
        public var value: String
        public var source: SuggestionSource
        public var confidence: Double

        public init(value: String, source: SuggestionSource, confidence: Double) {
            self.value = value
            self.source = source
            self.confidence = confidence
        }

        public var id: String { "\(source.rawValue)|\(value)" }
    }

    public var id: MetadataField { field }

    public init(
        field: MetadataField,
        value: String,
        currentValue: String,
        source: SuggestionSource,
        confidence: Double,
        isAccepted: Bool,
        alternatives: [Alternative] = []
    ) {
        self.field = field
        self.value = value
        self.currentValue = currentValue
        self.source = source
        self.confidence = confidence
        self.isAccepted = isAccepted
        self.alternatives = alternatives
    }

    /// Schaltet auf eine Alternative um. Der bisherige Wert geht nicht
    /// verloren, sondern wird selbst zur Alternative — der Nutzer soll
    /// zurückwechseln können, ohne den Lauf zu wiederholen.
    public mutating func select(_ alternative: Alternative) {
        guard alternative.value != value else { return }
        let previous = Alternative(value: value, source: source, confidence: confidence)
        alternatives.removeAll { $0.value == alternative.value }
        if !alternatives.contains(where: { $0.value == previous.value }) {
            alternatives.insert(previous, at: 0)
        }
        value = alternative.value
        source = alternative.source
        confidence = alternative.confidence
    }

    /// Übernimmt einen von Hand eingegebenen Wert. Der bisherige Vorschlag
    /// bleibt als Alternative stehen, die Confidence ist per Definition voll —
    /// der Mensch hat hingeschaut.
    /// Getrimmt wird bewusst **nicht** hier, sondern erst beim Schreiben:
    /// sonst verschluckt das Feld jedes Leerzeichen, das der Nutzer gerade
    /// zwischen zwei Wörtern tippt.
    public mutating func setManualValue(_ newValue: String) {
        guard newValue != value else { return }
        if source != .manual,
           !value.isEmpty,
           !alternatives.contains(where: { $0.value == value }) {
            alternatives.insert(
                Alternative(value: value, source: source, confidence: confidence),
                at: 0
            )
        }
        value = newValue
        source = .manual
        confidence = 1.0
    }

    /// Der Vorschlag würde einen bestehenden Wert ersetzen.
    public var isOverwrite: Bool {
        !currentValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Vorschlag und Bestand sind praktisch dasselbe — nichts zu tun.
    public var isRedundant: Bool {
        isOverwrite && TextSimilarity.similarity(value, currentValue) >= 0.98
    }
}

/// Confidence-Stufen für die Anzeige. Die Schwellen liegen hier, damit UI und
/// Auto-Auswahl dieselbe Skala benutzen.
public enum SuggestionConfidence: String, Sendable {
    case high
    case medium
    case low

    public static func level(_ value: Double) -> SuggestionConfidence {
        if value >= 0.85 { return .high }
        if value >= 0.65 { return .medium }
        return .low
    }

    /// Ab hier wird ein **fehlendes** Feld vorausgewählt.
    public static let autoAcceptThreshold = 0.75
}

/// Maschinenlesbare Randnotiz zu einem Vorschlag. Die Übersetzung passiert im
/// UI-Layer — `SetCraftCore` hat keinen String-Katalog.
public enum ProposalNote: String, Sendable, CaseIterable {
    /// Es gibt keinen Hinweis, welche Seite Artist und welche Titel ist.
    case orderAmbiguous
    /// Getrennt wurde nur an einem nackten Bindestrich.
    case weakSeparator
    /// Gar kein Trenner — Artist konnte nicht bestimmt werden.
    case noSeparator
    /// Das Ordner-Schema hat die Reihenfolge geklärt.
    case folderPatternApplied
    /// Ordner-Schema war „Title - Artist", die Seiten wurden getauscht.
    case folderPatternSwapped
    /// Tags von einem getaggten Zwilling übernommen.
    case libraryDuplicate
    /// Bit-identische Datei gefunden.
    case identicalFileFound
    /// Der Katalog bestätigt den Offline-Vorschlag.
    case catalogConfirmed
    /// Der Katalog widerspricht — sein Wert steht im Vorschlag, der Offline-Wert
    /// bleibt als Bestand sichtbar.
    case catalogCorrected
    /// Katalog wurde gefragt, kennt den Track aber nicht.
    case catalogNoMatch
    /// Mehrere plausible Katalog-Treffer; genommen wurde der beste.
    case catalogAmbiguous
    /// Katalog-Abfrage fiel wegen Rate-Limit oder Netzfehler aus.
    case catalogUnavailable
    /// Katalog wurde nach Policy nicht gefragt.
    case catalogNotChecked
}

/// Vollständiger Vorschlag für **einen** Track.
public struct MetadataProposal: Sendable, Identifiable {
    /// Die Datei ist die Identität — `Track.id` wird pro Scan neu vergeben.
    public var url: URL
    /// Zustand, wie er beim Bauen des Vorschlags in der Bibliothek stand.
    public var track: Track
    /// Was der Parser (ggf. nach Ordner-Schema) aus dem Namen gelesen hat.
    public var parsed: ParsedFilename
    /// Vorschläge pro Feld, stabil sortiert nach `MetadataField.allCases`.
    public var fields: [FieldSuggestion]
    public var notes: [ProposalNote]
    /// Kennung des Katalog-Treffers, falls einer verwendet wurde
    /// (z. B. `discogs:release/1#B2`) — landet als Provenienz im Log.
    public var catalogReference: String?
    /// Warum die Katalog-Abfrage scheiterte, im Klartext. Gehört in die UI:
    /// ein blosses „nicht erreichbar" kostete schon einmal eine Runde
    /// Fehlersuche, obwohl der Grund (fehlendes Sandbox-Entitlement) in der
    /// Fehlermeldung stand.
    public var catalogErrorDescription: String?

    public var id: URL { url }

    public init(
        url: URL,
        track: Track,
        parsed: ParsedFilename,
        fields: [FieldSuggestion] = [],
        notes: [ProposalNote] = [],
        catalogReference: String? = nil,
        catalogErrorDescription: String? = nil
    ) {
        self.url = url
        self.track = track
        self.parsed = parsed
        self.fields = fields
        self.notes = notes
        self.catalogReference = catalogReference
        self.catalogErrorDescription = catalogErrorDescription
    }

    /// Niedrigste Confidence der tatsächlich angehakten Felder — danach
    /// sortiert das Review-Sheet, damit Wackelkandidaten oben stehen.
    public var confidence: Double {
        let relevant = fields.filter { !$0.isRedundant }
        guard !relevant.isEmpty else { return 1.0 }
        return relevant.map(\.confidence).min() ?? 0
    }

    public var confidenceLevel: SuggestionConfidence {
        SuggestionConfidence.level(confidence)
    }

    /// Es gibt überhaupt etwas zu entscheiden.
    public var hasChanges: Bool {
        fields.contains { !$0.isRedundant }
    }

    public func suggestion(for field: MetadataField) -> FieldSuggestion? {
        fields.first { $0.field == field }
    }

    /// Baut den Track, der geschrieben werden soll — nur angehakte Felder
    /// wandern hinein. Alles andere (BPM, Key, Rating, Kommentar) bleibt
    /// unangetastet.
    public func applied(to base: Track) -> Track {
        var result = base
        for suggestion in fields where suggestion.isAccepted {
            let value = suggestion.value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch suggestion.field {
            case .artist: result.artist = value
            case .title:  result.title = value
            case .album:  result.album = value
            case .label:  result.label = value
            case .year:   result.year = Int(value) ?? result.year
            }
        }
        return result
    }
}
