import Foundation

/// Decodable-Hüllen für die Discogs-API (api.discogs.com, v2).
///
/// Bewusst nur die Felder, die SetCraft braucht — Discogs liefert pro Release
/// ein Vielfaches davon (Marktplatz-Preise, Community-Stats, Bilder). Alle
/// Felder sind optional, weil die Datenqualität je Release schwankt: bei
/// Vinyl-Einträgen fehlen Dauern regelmässig, bei Promos ganze Labelangaben.
enum Discogs {

    struct SearchResponse: Decodable {
        let results: [SearchResult]
    }

    /// Ein Suchtreffer. Achtung: Discogs sucht auf **Release**-Ebene und
    /// liefert Artist und Titel nur zusammengeklebt in `title`
    /// („The Persuader - Stockholm"). Die saubere Trennung und die Tracklist
    /// gibt es erst über `GET /releases/{id}` — daher zwei Requests pro Track.
    struct SearchResult: Decodable {
        let id: Int
        let title: String?
        let year: String?
        let catno: String?
        let label: [String]?
        let format: [String]?
        let type: String?
    }

    struct Release: Decodable {
        let id: Int
        let title: String?
        let year: Int?
        let artists: [Artist]?
        let labels: [Label]?
        let tracklist: [TrackEntry]?
    }

    struct Artist: Decodable {
        let name: String?
        /// „Artist Name Variation" — wie der Name auf **diesem** Release steht.
        let anv: String?
        /// Verbinder zum nächsten Artist („&", „feat.", „vs").
        let join: String?
    }

    struct Label: Decodable {
        let name: String?
        let catno: String?
    }

    struct TrackEntry: Decodable {
        let position: String?
        let title: String?
        /// „4:45" — bei Vinyl-Releases oft leer.
        let duration: String?
        /// „track", „heading", „index". Überschriften sind keine Tracks.
        let kind: String?
        let artists: [Artist]?

        enum CodingKeys: String, CodingKey {
            case position, title, duration, artists
            case kind = "type_"
        }

        var isPlayableTrack: Bool {
            guard let kind, !kind.isEmpty else { return true }
            return kind == "track"
        }

        /// Dauer in Sekunden aus „m:ss" bzw. „h:mm:ss".
        var durationSeconds: TimeInterval? {
            guard let duration, !duration.isEmpty else { return nil }
            let parts = duration.split(separator: ":").compactMap { Int($0) }
            guard !parts.isEmpty else { return nil }
            return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
        }
    }
}

extension Array where Element == Discogs.Artist {

    /// Baut den Artist-String so zusammen, wie er auf dem Release steht —
    /// inklusive der Verbinder („A & B", „A feat. B").
    ///
    /// Discogs hängt an mehrfach vergebene Künstlernamen eine Nummer:
    /// „Sabre (2)". Die gehört nicht in ein Tag und wird entfernt.
    var joinedName: String {
        var result = ""
        for (index, artist) in enumerated() {
            let name = (artist.anv?.isEmpty == false ? artist.anv : artist.name) ?? ""
            result += Discogs.stripDisambiguation(name)
            if index < count - 1 {
                let join = artist.join?.trimmingCharacters(in: .whitespaces) ?? ""
                result += join.isEmpty ? ", " : " \(join) "
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

extension Discogs {
    /// Entfernt Discogs' Eindeutigkeits-Suffix („Sabre (2)" → „Sabre").
    static func stripDisambiguation(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"\s*\(\d+\)\s*$"#,
            with: "",
            options: .regularExpression
        )
    }
}
