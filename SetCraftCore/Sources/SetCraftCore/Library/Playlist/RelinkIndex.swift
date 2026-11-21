import Foundation

/// Sucht zu einem Playlist-Eintrag, dessen Pfad nicht (mehr) stimmt, die
/// passende Datei unter den bekannten Dateien der Bibliothek.
///
/// Stufen nach Spec §4, die erste Stufe mit Treffern gewinnt:
/// 1. gleicher Pfad-Schwanz (letzte 3, dann 2 Segmente),
/// 2. gleicher Dateiname,
/// 3. gleicher Dateiname ohne Gross-/Kleinschreibung, Unicode-normalisiert
///    (NFC/NFD — ein NAS liefert Umlaute gern zerlegt).
///
/// Reine Datenstruktur: welche Dateien hineinkommen (flaches Listing der
/// Ordnerquellen plus Pfade aus dem Track-Cache), entscheidet der Aufrufer.
public struct RelinkIndex: Sendable {

    private let byName: [String: [URL]]
    private let byNormalizedName: [String: [URL]]

    public init(files: [URL]) {
        var byName: [String: [URL]] = [:]
        var byNormalizedName: [String: [URL]] = [:]
        var seen = Set<String>()
        for file in files {
            let url = file.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            byName[url.lastPathComponent, default: []].append(url)
            byNormalizedName[Self.normalize(url.lastPathComponent), default: []].append(url)
        }
        self.byName = byName
        self.byNormalizedName = byNormalizedName
    }

    public var isEmpty: Bool { byName.isEmpty }

    /// Kandidaten der ersten Stufe, die etwas findet — leer, wenn keine.
    /// Mehr als ein Kandidat heisst: der Nutzer muss wählen.
    public func candidates(for location: PlaylistLocation) -> [URL] {
        guard let name = location.fileName else { return [] }
        let components = location.pathComponents

        if let exact = byName[name] {
            for tail in [3, 2] where components.count >= tail {
                let wanted = Array(components.suffix(tail))
                let hits = exact.filter { Array($0.pathComponents.suffix(tail)) == wanted }
                if !hits.isEmpty { return hits }
            }
            return exact
        }
        return byNormalizedName[Self.normalize(name)] ?? []
    }

    /// Kleinbuchstaben, Akzente bleiben erhalten, Komposition vereinheitlicht.
    static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
