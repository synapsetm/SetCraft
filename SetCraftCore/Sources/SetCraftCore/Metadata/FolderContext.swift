import Foundation

/// Was der **Ordner** über seine Dateien verrät.
///
/// Zwei Quellen: der Ordnername selbst (`Artist - Album (1999)` ist die
/// verbreitetste Konvention überhaupt) und die Einstimmigkeit der getaggten
/// Geschwister. Beides hilft genau dort, wo der Dateiname nur `01 Title.mp3`
/// hergibt.
public struct FolderContext: Sendable, Equatable {

    /// Album aus dem Ordnernamen bzw. aus einstimmigen Geschwister-Tags.
    public var album: String = ""
    /// Artist aus dem Ordnernamen — nur als Rückfall, wenn der Dateiname
    /// keinen hergibt. Bei Compilations ist er falsch, darum niedrig gewichtet.
    public var albumArtist: String = ""
    public var year: Int?
    /// Label, falls alle getaggten Geschwister dasselbe tragen.
    public var label: String = ""

    public init() {}

    public var isEmpty: Bool {
        album.isEmpty && albumArtist.isEmpty && year == nil && label.isEmpty
    }

    /// Ordnernamen, die nichts über den Inhalt sagen. Aus denen lesen wir
    /// kein Album heraus.
    static let genericFolderNames: Set<String> = [
        "music", "musik", "tracks", "downloads", "download", "new", "neu",
        "incoming", "unsorted", "misc", "various", "va", "dj", "sets",
        "techno", "house", "dnb", "drum and bass", "dubstep", "electro",
        "minimal", "ambient", "itunes", "media", "audio", "mp3", "mp3s",
        "flac", "library", "promo", "promos", "desktop", "documents"
    ]

    /// Liest Album/Artist/Jahr aus dem Ordnernamen.
    public static func fromFolderName(_ folder: URL) -> FolderContext {
        var context = FolderContext()
        let raw = folder.lastPathComponent
        let parsed = FilenameParser.parse(stem: raw)
        context.year = parsed.year

        let name = parsed.cleanedStem
        guard !name.isEmpty else { return context }

        if parsed.hasSeparator, !parsed.separatorWasWeak {
            context.albumArtist = parsed.artist
            context.album = parsed.title
        } else if !Self.genericFolderNames.contains(TextSimilarity.normalize(name)),
                  Int(name) == nil {   // reine Jahreszahl-Ordner sind kein Album
            context.album = name
        }
        return context
    }

    /// Ergänzt Album/Label/Jahr, wenn die getaggten Geschwister sich einig
    /// sind. Geschwister-Einstimmigkeit schlägt den Ordnernamen, weil sie
    /// aus echten Tags kommt.
    public static func merging(folder: URL, siblings: [Track]) -> FolderContext {
        var context = fromFolderName(folder)

        if let album = consensus(of: siblings.map(\.album)) {
            context.album = album
        }
        if let label = consensus(of: siblings.map(\.label)) {
            context.label = label
        }
        if let year = consensus(of: siblings.compactMap(\.year).map(String.init)) {
            context.year = Int(year)
        }
        return context
    }

    /// Einstimmiger Wert einer Spalte — mindestens zwei Belege und keine
    /// Gegenstimme. „Fast einstimmig" lassen wir bewusst fallen: ein Ordner
    /// mit zwei Alben darf keines von beiden auf alle Dateien vererben.
    static func consensus(of values: [String]) -> String? {
        let filled = values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled.count >= 2 else { return nil }
        let distinct = Set(filled.map { TextSimilarity.normalize($0) })
        guard distinct.count == 1 else { return nil }
        return filled[0]
    }
}
