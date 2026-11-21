import Foundation

/// Schreibt eine M3U8 im Format, das Rekordbox und Serato importieren:
/// UTF-8 ohne BOM, `\n` als Zeilenende, `#EXTINF` mit ganzen Sekunden.
///
/// Reine Textproduktion — das Speichern übernimmt der Aufrufer (Save-Panel
/// bzw. Teilen-Menü). Persistiert werden nur Werte, die so auch im Tag
/// stehen; Wiedergabewerte (gespielter BPM/Key) kommen gar nicht erst herein.
public enum M3UWriter {

    public enum PathStyle: Sendable {
        /// Absolute Pfade — für Rekordbox/Traktor auf demselben Rechner.
        case absolute
        /// Relativ zum Verzeichnis der M3U, für USB-Stick oder Ordner, in dem
        /// Playlist und Musik zusammen liegen.
        case relative(toPlaylistAt: URL)
    }

    public struct Item: Sendable {
        /// `nil` für Einträge ohne Datei — werden übersprungen und gezählt.
        public var url: URL?
        public var durationSeconds: TimeInterval
        public var artist: String
        public var title: String

        public init(url: URL?, durationSeconds: TimeInterval, artist: String, title: String) {
            self.url = url
            self.durationSeconds = durationSeconds
            self.artist = artist
            self.title = title
        }

        public init(track: Track) {
            self.init(url: track.url,
                      durationSeconds: track.durationSeconds,
                      artist: track.artist,
                      title: track.title)
        }
    }

    public struct Result: Sendable {
        public var text: String
        public var writtenCount: Int
        /// Einträge ohne Datei, nicht exportiert.
        public var skippedMissingCount: Int
        /// Bei `.relative`: Einträge auf einem anderen Volume, absolut geschrieben.
        public var absoluteFallbackCount: Int

        public var data: Data { Data(text.utf8) }
    }

    public static func write(_ items: [Item], pathStyle: PathStyle = .absolute) -> Result {
        var lines = ["#EXTM3U"]
        var written = 0
        var skipped = 0
        var fallbacks = 0

        for item in items {
            guard let url = item.url else {
                skipped += 1
                continue
            }
            lines.append(extInf(for: item, url: url))

            let path: String
            switch pathStyle {
            case .absolute:
                path = url.standardizedFileURL.path
            case .relative(let playlistURL):
                if let relative = relativePath(from: playlistURL.deletingLastPathComponent(), to: url) {
                    path = relative
                } else {
                    path = url.standardizedFileURL.path
                    fallbacks += 1
                }
            }
            lines.append(path)
            written += 1
        }

        return Result(text: lines.joined(separator: "\n") + "\n",
                      writtenCount: written,
                      skippedMissingCount: skipped,
                      absoluteFallbackCount: fallbacks)
    }

    static func extInf(for item: Item, url: URL) -> String {
        let seconds = item.durationSeconds > 0 ? Int(item.durationSeconds.rounded()) : -1
        let artist = singleLine(item.artist)
        var title = singleLine(item.title)
        if title.isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }
        let display = artist.isEmpty ? title : "\(artist) - \(title)"
        return "#EXTINF:\(seconds),\(display)"
    }

    private static func singleLine(_ text: String) -> String {
        // `\r\n` zerfällt hier in zwei Trenner mit leerem Stück dazwischen.
        text.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Relativer Pfad von `directory` zu `file`, oder `nil`, wenn beide auf
    /// verschiedenen Volumes liegen. Rein über die Pfade entschieden, ohne
    /// Dateisystem-Abfrage — die könnte auf einem NAS blockieren.
    static func relativePath(from directory: URL, to file: URL) -> String? {
        let base = directory.standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        guard volumeRoot(of: base) == volumeRoot(of: target) else { return nil }

        var common = 0
        while common < base.count, common < target.count - 1, base[common] == target[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }

    /// `/Volumes/<Name>` für externe Volumes und Netz-Shares, sonst `/`.
    private static func volumeRoot(of components: [String]) -> [String] {
        if components.count >= 3, components[1] == "Volumes" {
            return Array(components.prefix(3))
        }
        return ["/"]
    }
}
