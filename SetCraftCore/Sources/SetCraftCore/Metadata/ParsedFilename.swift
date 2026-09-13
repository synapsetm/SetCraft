import Foundation

/// Ergebnis des Dateinamen-Parsings. Reines Datum, kein Urteil — wie sicher
/// der Treffer ist, entscheidet der `MetadataResolverChain` anhand der Flags
/// (`hasSeparator`, `separatorWasWeak`, `orderIsAmbiguous`).
public struct ParsedFilename: Sendable, Equatable {
    /// Interpret, wie im Dateinamen geschrieben (inkl. „&"/„vs"-Kombis).
    public var artist: String = ""
    /// Titel **inklusive** Mix-Klammer — Serato und Rekordbox zeigen nur den
    /// Titel, „(Extended Mix)" muss also dort drinstehen.
    public var title: String = ""
    /// Mix-/Versionsbezeichnung ohne Klammern, z. B. „Extended Mix".
    /// Zusätzlich separat geführt, damit die Vollständigkeitsprüfung merkt,
    /// wenn sie fehlt, und Discogs gezielt danach suchen kann.
    public var mixVersion: String = ""
    /// Gast-Interpret aus „feat."/„ft." — bleibt im Titel stehen, steht hier
    /// nur für den Katalog-Abgleich nochmals isoliert.
    public var featuring: String = ""
    /// Jahr aus einer Klammer im Dateinamen (`(1999)`), falls vorhanden.
    public var year: Int?
    /// Label-Katalognummer am Anfang (`SK032 - …`), typisch bei Promos.
    public var catalogNumber: String = ""
    /// Tracknummer-Präfix (`03 - …`) bzw. Vinyl-Position (`B2 - …`).
    public var trackNumber: Int?
    public var vinylPosition: String = ""
    /// Ein Artist/Title-Trenner wurde gefunden.
    public var hasSeparator: Bool = false
    /// Der Trenner war nur ein nackter Bindestrich ohne Leerzeichen
    /// (`Artist-Title`) — deutlich unzuverlässiger, weil Namen wie
    /// „Jean-Michel Jarre" genauso aussehen.
    public var separatorWasWeak: Bool = false
    /// Es gibt kein Signal, welche Seite Artist und welche Titel ist.
    /// „Title - Artist" kommt in echten Sammlungen häufig vor; auflösen
    /// kann das nur ein Katalog-Abgleich.
    public var orderIsAmbiguous: Bool = true
    /// Der von Rip-Resten befreite Dateiname ohne Endung — Basis für alle
    /// weiteren Schritte und für die Anzeige im Review-Sheet.
    public var cleanedStem: String = ""

    public init() {}

    /// Minimal brauchbar: irgendein Titel ist da.
    public var isUsable: Bool {
        !title.isEmpty
    }

    /// Beide Kernfelder gefüllt.
    public var isComplete: Bool {
        !title.isEmpty && !artist.isEmpty
    }

    /// Für den Katalog-Abgleich: „Artist Title" ohne Mix-Klammer.
    public var searchQuery: String {
        let bare = FilenameParser.withoutTrailingBracket(title)
        return [artist, bare]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
