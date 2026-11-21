import Foundation

/// Wohin eine Pfadzeile einer M3U zeigt — so, wie sie in der Datei steht,
/// noch **ohne** Dateisystem-Zugriff. Ob die Datei existiert und ob die
/// Sandbox sie freigibt, entscheidet erst die Pfadauflösung.
public enum PlaylistLocation: Hashable, Sendable {
    /// Lokaler Pfad: absolut, relativ zur M3U aufgelöst oder aus `file://`.
    case local(URL)
    /// Windows-Pfad (`C:\…`, `\\server\…`). Auf dem Mac nicht erreichbar —
    /// brauchbar ist nur der Dateiname, für den Relink.
    case foreign(path: String)
    /// `http(s)://` und andere Netz-Schemata — wird nicht unterstützt.
    case remote(URL)

    /// Dateiname, wie ihn der Relink sucht. `nil` bei Netz-Einträgen.
    public var fileName: String? {
        switch self {
        case .local(let url):
            return url.lastPathComponent
        case .foreign(let path):
            let name = path.split(separator: "/").last.map(String.init)
            return name?.isEmpty == false ? name : nil
        case .remote:
            return nil
        }
    }

    /// Pfadsegmente für den Relink über den Pfad-Schwanz.
    public var pathComponents: [String] {
        switch self {
        case .local(let url):
            return url.pathComponents.filter { $0 != "/" }
        case .foreign(let path):
            return path.split(separator: "/").map(String.init)
        case .remote:
            return []
        }
    }
}

/// Ein Eintrag einer M3U, in Datei-Reihenfolge. Duplikate bleiben als
/// eigene Einträge erhalten.
public struct PlaylistEntry: Hashable, Sendable {
    /// Position in der Playlist, ab 1 — das, was die Spalte «#» zeigt.
    public var index: Int
    /// Pfadzeile unverändert aus der Datei, für Tooltip und Relink-Speicher.
    public var rawLine: String
    public var location: PlaylistLocation
    /// Dauer aus `#EXTINF` in ganzen Sekunden; `nil` bei `-1` oder ohne `#EXTINF`.
    public var extDuration: Int?
    public var extArtist: String?
    public var extTitle: String?

    public init(index: Int,
                rawLine: String,
                location: PlaylistLocation,
                extDuration: Int? = nil,
                extArtist: String? = nil,
                extTitle: String? = nil) {
        self.index = index
        self.rawLine = rawLine
        self.location = location
        self.extDuration = extDuration
        self.extArtist = extArtist
        self.extTitle = extTitle
    }
}

/// Liest M3U/M3U8-Playlists. Reine Textverarbeitung: das Lesen der Datei
/// selbst (`parse(contentsOf:)`) ist der einzige Dateizugriff und gehört beim
/// Aufrufer auf eine eigene Queue, weil die Playlist auf einem NAS liegen kann.
public enum M3UParser {

    /// Liest und parst die Playlist unter `url`. Relative Pfade werden gegen
    /// das Verzeichnis der Playlist aufgelöst.
    public static func parse(contentsOf url: URL) throws -> [PlaylistEntry] {
        let data = try Data(contentsOf: url)
        let isM3U8 = url.pathExtension.lowercased() == "m3u8"
        return parse(text: decode(data, assumeUTF8: isM3U8),
                     baseDirectory: url.deletingLastPathComponent())
    }

    /// Zeichensatz nach Spec: `.m3u8` immer UTF-8, `.m3u` zuerst UTF-8 und
    /// bei ungültigen Bytes Windows-1252. Ein BOM wird in beiden Fällen entfernt.
    public static func decode(_ data: Data, assumeUTF8: Bool) -> String {
        var bytes = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.starts(with: bom) {
            bytes = bytes.dropFirst(bom.count)
        }
        if let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        if !assumeUTF8, let text = String(data: bytes, encoding: .windowsCP1252) {
            return text
        }
        // Kaputtes UTF-8 in einer .m3u8: lieber Ersatzzeichen als gar nichts —
        // die Pfade, die heil sind, bleiben so ladbar.
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func parse(text: String, baseDirectory: URL) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pendingInfo: ExtInf?

        // `\r\n` ist in Swift ein einziges Character-Grapheme, deshalb über
        // die Unicode-Skalare trennen — sonst rutscht CRLF als ganzes durch.
        let lines = text.unicodeScalars
            .split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" }
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespaces) }

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#EXTINF:") {
                    pendingInfo = ExtInf(line: line)
                }
                // Alle anderen Direktiven (#EXTM3U, #EXTVLCOPT, #PLAYLIST …)
                // ignorieren — und #EXTINF dabei nicht verwerfen.
                continue
            }
            entries.append(PlaylistEntry(
                index: entries.count + 1,
                rawLine: line,
                location: location(for: line, baseDirectory: baseDirectory),
                extDuration: pendingInfo?.duration,
                extArtist: pendingInfo?.artist,
                extTitle: pendingInfo?.title
            ))
            pendingInfo = nil
        }
        return entries
    }

    // MARK: - Pfadformen

    static func location(for line: String, baseDirectory: URL) -> PlaylistLocation {
        if let url = URL(string: line), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            if scheme == "file" {
                // `file:///…` und `file://localhost/…`; `.path` dekodiert %20.
                return .local(URL(fileURLWithPath: url.path).standardizedFileURL)
            }
            return .remote(url)
        }
        if isWindowsPath(line) {
            return .foreign(path: line.replacingOccurrences(of: "\\", with: "/"))
        }
        // Relative Pfade mit Backslash (`Tracks\abc.mp3`) sind nach dem
        // Normalisieren gewöhnliche relative Pfade.
        let path = line.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") {
            return .local(URL(fileURLWithPath: path).standardizedFileURL)
        }
        if path.hasPrefix("~/") {
            // Gibt es in der Sandbox nicht sinnvoll aufzulösen; als absoluter
            // Pfad unter dem echten Home behandeln, damit der Relink greift.
            let expanded = (path as NSString).expandingTildeInPath
            return .local(URL(fileURLWithPath: expanded).standardizedFileURL)
        }
        return .local(baseDirectory.appendingPathComponent(path).standardizedFileURL)
    }

    /// `C:\…`, `C:/…` oder UNC `\\server\…`.
    static func isWindowsPath(_ line: String) -> Bool {
        if line.hasPrefix("\\\\") { return true }
        let chars = Array(line.prefix(3))
        return chars.count == 3
            && chars[0].isASCII && chars[0].isLetter
            && chars[1] == ":"
            && (chars[2] == "\\" || chars[2] == "/")
    }

    // MARK: - #EXTINF

    struct ExtInf {
        var duration: Int?
        var artist: String?
        var title: String?

        /// `#EXTINF:<sek>[ attr="…"],<Artist> - <Title>`
        init(line: String) {
            let body = line.dropFirst("#EXTINF:".count)
            let comma = body.firstIndex(of: ",")
            let head = comma.map { body[..<$0] } ?? body
            let durationText = head.split(separator: " ").first.map(String.init) ?? ""
            if let seconds = Double(durationText), seconds >= 0 {
                duration = Int(seconds.rounded())
            }

            guard let comma else { return }
            let display = body[body.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            guard !display.isEmpty else { return }
            if let separator = display.range(of: " - ") {
                let a = display[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                let t = display[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                artist = a.isEmpty ? nil : a
                title = t.isEmpty ? nil : t
            } else {
                title = display
            }
        }
    }
}
