import Foundation

/// Eigene Queue für Lesen und Prüfen der Playlist-Pfade: jeder `stat` auf
/// eine Provider-URL kann blockieren, solange das NAS nicht antwortet.
/// Gleiche Begründung wie bei `folderScanQueue` in `LibraryRepository`.
private let playlistQueue = DispatchQueue(
    label: "ch.buehler.beat.SetCraft.playlist",
    qos: .userInitiated
)

/// Ergebnis der Auflösung eines Playlist-Eintrags.
public enum PlaylistEntryStatus: Hashable, Sendable {
    /// Pfad stimmt und liegt in einer freigegebenen Quelle.
    case resolved(URL)
    /// Über Relink (oder gespeicherte Zuordnung) gefunden — dezenter Hinweis.
    case relinked(URL)
    /// Datei existiert, aber kein Ordner mit Bookmark deckt sie ab.
    case noAccess(URL)
    /// Relink hat mehrere Kandidaten gefunden, der Nutzer muss wählen.
    case ambiguous([URL])
    /// Nicht gefunden — Aktion «Locate…».
    case missing
    /// `http(s)://` und andere Netz-Einträge.
    case unsupported

    /// Datei, die geladen werden kann.
    public var fileURL: URL? {
        switch self {
        case .resolved(let url), .relinked(let url): return url
        default: return nil
        }
    }
}

public struct ResolvedPlaylistEntry: Hashable, Sendable {
    public var entry: PlaylistEntry
    public var status: PlaylistEntryStatus
}

/// Was das Dateisystem zu einem Pfad sagt. Getrennt vom Resolver, damit der
/// testbar bleibt und der echte Zugriff auf einer eigenen Queue läuft.
public enum FileProbeResult: Sendable {
    case exists
    /// `EPERM`/`EACCES` — die Sandbox verweigert, die Datei ist aber da.
    case noPermission
    case notFound
}

/// Löst die Einträge einer Playlist auf (Spec §2 und §4). Reine Logik: das
/// Dateisystem kommt als `probe` herein, die bekannten Dateien als
/// `RelinkIndex`, gespeicherte Zuordnungen als `storedLinks`.
public enum PlaylistResolver {

    public struct Context: Sendable {
        /// Ordner mit gültigem Bookmark (Ordnerquellen der Bibliothek).
        public var grantedRoots: [URL]
        public var relinkIndex: RelinkIndex
        /// Gespeicherte Relinks: `rawLine` → aufgelöster Pfad.
        public var storedLinks: [String: String]
        /// `false` auf iOS: absolute Mac-Pfade sind dort nie freigebbar,
        /// ein «kein Zugriff» ergäbe nur einen sinnlosen Freigabe-Dialog.
        public var canRequestAccess: Bool

        public init(grantedRoots: [URL],
                    relinkIndex: RelinkIndex,
                    storedLinks: [String: String] = [:],
                    canRequestAccess: Bool = true) {
            self.grantedRoots = grantedRoots
            self.relinkIndex = relinkIndex
            self.storedLinks = storedLinks
            self.canRequestAccess = canRequestAccess
        }
    }

    /// Liest die Playlist und löst sie auf, beides auf `playlistQueue`.
    /// Der Aufrufer muss den Scope der M3U und der Ordnerquellen offen halten.
    public static func load(
        playlistAt url: URL,
        context: Context
    ) async throws -> [ResolvedPlaylistEntry] {
        try await withCheckedThrowingContinuation { continuation in
            playlistQueue.async {
                continuation.resume(with: Result {
                    let entries = try M3UParser.parse(contentsOf: url)
                    return resolve(entries, context: context, probe: fileSystemProbe)
                })
            }
        }
    }

    /// Wie `resolve(_:context:probe:)` mit echtem Dateisystem, aber auf
    /// `playlistQueue` — für den zweiten Durchlauf mit vollem Relink-Index.
    public static func resolve(
        _ entries: [PlaylistEntry],
        context: Context
    ) async -> [ResolvedPlaylistEntry] {
        await withCheckedContinuation { continuation in
            playlistQueue.async {
                continuation.resume(returning: resolve(entries, context: context, probe: fileSystemProbe))
            }
        }
    }

    /// Flaches Listing der Audiodateien in `folders` — Kandidaten für den
    /// Relink. Auf `playlistQueue`, weil jedes Listing auf einem NAS blockieren
    /// kann.
    public static func collectAudioFiles(in folders: [URL]) async -> [URL] {
        await withCheckedContinuation { continuation in
            playlistQueue.async {
                continuation.resume(returning: folders.flatMap(FolderScanner.collectAudioFiles(in:)))
            }
        }
    }

    /// Löst Security-Scoped Bookmarks auf, ohne Volumes zu mounten oder UI zu
    /// zeigen — ein nicht verbundenes NAS soll das Öffnen der Playlist nicht
    /// aufhalten. `nil` für jedes Bookmark, das nicht auflösbar ist.
    public static func resolveBookmarks(_ bookmarks: [Data]) async -> [URL?] {
        await withCheckedContinuation { continuation in
            playlistQueue.async {
                let urls = bookmarks.map { data -> URL? in
                    var isStale = false
                    #if os(macOS)
                    let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
                    #else
                    let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
                    #endif
                    return try? URL(resolvingBookmarkData: data, options: options,
                                    relativeTo: nil, bookmarkDataIsStale: &isStale)
                }
                continuation.resume(returning: urls)
            }
        }
    }

    public static func resolve(
        _ entries: [PlaylistEntry],
        context: Context,
        probe: (URL) -> FileProbeResult
    ) -> [ResolvedPlaylistEntry] {
        entries.map { entry in
            ResolvedPlaylistEntry(entry: entry,
                                  status: status(for: entry, context: context, probe: probe))
        }
    }

    static func status(
        for entry: PlaylistEntry,
        context: Context,
        probe: (URL) -> FileProbeResult
    ) -> PlaylistEntryStatus {
        if let stored = context.storedLinks[entry.rawLine] {
            let url = URL(fileURLWithPath: stored)
            if isCovered(url, by: context.grantedRoots), probe(url) == .exists {
                return .relinked(url)
            }
        }

        switch entry.location {
        case .remote:
            return .unsupported

        case .local(let url):
            if isCovered(url, by: context.grantedRoots) {
                if probe(url) == .exists { return .resolved(url) }
            } else if context.canRequestAccess {
                switch probe(url) {
                case .exists, .noPermission: return .noAccess(url)
                case .notFound: break
                }
            }
            return relink(entry.location, index: context.relinkIndex)

        case .foreign:
            return relink(entry.location, index: context.relinkIndex)
        }
    }

    private static func relink(_ location: PlaylistLocation, index: RelinkIndex) -> PlaylistEntryStatus {
        let hits = index.candidates(for: location)
        switch hits.count {
        case 0:  return .missing
        case 1:  return .relinked(hits[0])
        default: return .ambiguous(hits)
        }
    }

    static func isCovered(_ url: URL, by roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let base = root.standardizedFileURL.path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// Kleinster gemeinsamer übergeordneter Ordner aller Einträge ohne
    /// Zugriff — Vorauswahl für den einen Freigabe-Dialog. `nil` bei leerer
    /// Liste.
    public static func commonAncestor(of urls: [URL]) -> URL? {
        let directories = urls.map { $0.standardizedFileURL.deletingLastPathComponent().pathComponents }
        guard var common = directories.first else { return nil }
        for components in directories.dropFirst() {
            var n = 0
            while n < common.count, n < components.count, common[n] == components[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        guard !common.isEmpty else { return URL(fileURLWithPath: "/") }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    /// Echte Prüfung über `stat`, die `EPERM` von `ENOENT` unterscheidet.
    /// Kann bei einer Netz-Quelle blockieren — nur von einer eigenen Queue
    /// aufrufen, nie vom MainActor.
    public static func fileSystemProbe(_ url: URL) -> FileProbeResult {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return (info.st_mode & S_IFMT) == S_IFREG ? .exists : .notFound
        }
        switch errno {
        case EPERM, EACCES: return .noPermission
        default:            return .notFound
        }
    }
}
