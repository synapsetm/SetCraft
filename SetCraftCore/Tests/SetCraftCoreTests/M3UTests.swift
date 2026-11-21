import XCTest
@testable import SetCraftCore

/// Fixtures stehen inline, damit Bytes (BOM, Windows-1252, CRLF) exakt
/// kontrolliert sind und das Paket keine Test-Ressourcen braucht.
/// Rekordbox- und Traktor-Fixtures sind nachgebaut, nicht echte Exporte.
final class M3UParserTests: XCTestCase {

    private let base = URL(fileURLWithPath: "/Volumes/share/Playlists")

    private func parse(_ text: String) -> [PlaylistEntry] {
        M3UParser.parse(text: text, baseDirectory: base)
    }

    private func path(_ entry: PlaylistEntry) -> String? {
        if case .local(let url) = entry.location { return url.path }
        return nil
    }

    // MARK: - Zeichensatz

    func test_decode_utf8WithBOM_stripsBOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("#EXTM3U\n/Musik/Café.mp3\n".utf8)
        let text = M3UParser.decode(data, assumeUTF8: true)
        XCTAssertTrue(text.hasPrefix("#EXTM3U"))
        let entries = parse(text)
        XCTAssertEqual(entries.map(path), ["/Musik/Café.mp3"])
    }

    func test_decode_windows1252Umlauts_inM3U() {
        // "/Musik/Grösse Ärger.mp3" in Windows-1252: ö = 0xF6, Ä = 0xC4
        var bytes = Array("/Musik/Gr".utf8)
        bytes.append(0xF6)
        bytes += Array("sse ".utf8)
        bytes.append(0xC4)
        bytes += Array("rger.mp3\n".utf8)
        let text = M3UParser.decode(Data(bytes), assumeUTF8: false)
        XCTAssertEqual(parse(text).map(path), ["/Musik/Grösse Ärger.mp3"])
    }

    func test_decode_validUTF8InM3U_staysUTF8() {
        let text = M3UParser.decode(Data("/Musik/Grösse.mp3".utf8), assumeUTF8: false)
        XCTAssertEqual(text, "/Musik/Grösse.mp3")
    }

    // MARK: - Zeilenenden

    func test_parse_CRLF_andCR_andBlankLines() {
        let text = "#EXTM3U\r\n\r\n/a/1.mp3\r\n/a/2.mp3\r/a/3.mp3\n\n"
        XCTAssertEqual(parse(text).map(path), ["/a/1.mp3", "/a/2.mp3", "/a/3.mp3"])
    }

    // MARK: - Pfadformen

    func test_parse_relativePaths_resolveAgainstPlaylistDirectory() {
        let entries = parse("Tracks/abc.mp3\n../Musik/def.mp3\n./ghi.mp3\n")
        XCTAssertEqual(entries.map(path), [
            "/Volumes/share/Playlists/Tracks/abc.mp3",
            "/Volumes/share/Musik/def.mp3",
            "/Volumes/share/Playlists/ghi.mp3"
        ])
    }

    func test_parse_relativeBackslashPath_isNormalized() {
        XCTAssertEqual(parse("Tracks\\abc.mp3").map(path),
                       ["/Volumes/share/Playlists/Tracks/abc.mp3"])
    }

    func test_parse_fileURL_withPercentEncoding() {
        let entries = parse("file:///Volumes/share/_INCOMING%20Traxx/One%20Function.mp3\nfile://localhost/a/b%C3%B6.mp3")
        XCTAssertEqual(entries.map(path), [
            "/Volumes/share/_INCOMING Traxx/One Function.mp3",
            "/a/bö.mp3"
        ])
    }

    func test_parse_windowsPaths_areForeign_withFileName() {
        let entries = parse("C:\\Users\\dj\\Music\\Track One.mp3\n\\\\nas\\music\\x.flac\nD:/Musik/y.wav")
        XCTAssertEqual(entries.map(\.location), [
            .foreign(path: "C:/Users/dj/Music/Track One.mp3"),
            .foreign(path: "//nas/music/x.flac"),
            .foreign(path: "D:/Musik/y.wav")
        ])
        XCTAssertEqual(entries.map(\.location.fileName), ["Track One.mp3", "x.flac", "y.wav"])
        XCTAssertEqual(entries[0].location.pathComponents.suffix(2), ["Music", "Track One.mp3"])
    }

    func test_parse_httpEntries_areRemote() {
        let entries = parse("https://example.com/stream.mp3\nhttp://radio.local:8000/live")
        guard case .remote = entries[0].location, case .remote = entries[1].location else {
            return XCTFail("expected remote entries: \(entries)")
        }
        XCTAssertNil(entries[0].location.fileName)
    }

    // MARK: - Direktiven

    func test_parse_withoutEXTM3U_works() {
        XCTAssertEqual(parse("/a/1.mp3\n/a/2.mp3").count, 2)
    }

    func test_parse_extinf_artistTitleDuration() {
        let entries = parse("#EXTM3U\n#EXTINF:447,One Function - Ajna (IKØN Remix)\n/a/1.mp3")
        XCTAssertEqual(entries[0].extDuration, 447)
        XCTAssertEqual(entries[0].extArtist, "One Function")
        XCTAssertEqual(entries[0].extTitle, "Ajna (IKØN Remix)")
    }

    func test_parse_extinf_splitsAtFirstSeparatorOnly() {
        let entries = parse("#EXTINF:300,Artist - Title - Extended Mix\n/a/1.mp3")
        XCTAssertEqual(entries[0].extArtist, "Artist")
        XCTAssertEqual(entries[0].extTitle, "Title - Extended Mix")
    }

    func test_parse_extinf_withoutArtist() {
        let entries = parse("#EXTINF:212,Just A Title\n/a/1.mp3")
        XCTAssertNil(entries[0].extArtist)
        XCTAssertEqual(entries[0].extTitle, "Just A Title")
    }

    func test_parse_extinf_negativeDuration_isNil() {
        let entries = parse("#EXTINF:-1,A - B\n/a/1.mp3")
        XCTAssertNil(entries[0].extDuration)
        XCTAssertEqual(entries[0].extArtist, "A")
    }

    func test_parse_extinf_withAttributes_andFractionalDuration() {
        let entries = parse("#EXTINF:181.6 tvg-id=\"x\",A - B\n/a/1.mp3")
        XCTAssertEqual(entries[0].extDuration, 182)
        XCTAssertEqual(entries[0].extTitle, "B")
    }

    func test_parse_extinf_appliesOnlyToNextPath_andSurvivesOtherDirectives() {
        let text = """
        #EXTINF:100,A - One
        #EXTVLCOPT:start-time=10
        /a/1.mp3
        /a/2.mp3
        """
        let entries = parse(text)
        XCTAssertEqual(entries[0].extTitle, "One")
        XCTAssertNil(entries[1].extTitle)
        XCTAssertNil(entries[1].extDuration)
    }

    func test_parse_preservesOrderAndDuplicates() {
        let entries = parse("/a/2.mp3\n/a/1.mp3\n/a/2.mp3")
        XCTAssertEqual(entries.map(path), ["/a/2.mp3", "/a/1.mp3", "/a/2.mp3"])
        XCTAssertEqual(entries.map(\.index), [1, 2, 3])
        XCTAssertEqual(entries[2].rawLine, "/a/2.mp3")
    }

    // MARK: - Exporte anderer Programme (nachgebaut)

    /// Nachgebildet nach einem echten Rekordbox-Export (M3U8, 2026-11), Namen
    /// und Pfade neutralisiert. Format wie im Original: CRLF, kein BOM,
    /// `Artist - Title`, mehrere Artists mit Komma, Tracks ohne Artist als
    /// `, - Title`.
    func test_parse_rekordboxExport() {
        let dir = "/Volumes/NAS/Music/Sets/Incoming"
        let text = [
            "#EXTM3U",
            "#EXTINF:230,Artist One, Featured Singer - First Track (Extended Mix)",
            "\(dir)/07. First Track (Extended Mix).flac",
            "#EXTINF:205,Artist Two - SECOND TRACK",
            "\(dir)/10. SECOND TRACK.flac",
            "#EXTINF:213, - Some_Artist_-_Third_Track_Extended_Mix_(example.com)",
            "\(dir)/Some_Artist_-_Third_Track_Extended_Mix_(example.com).mp3",
            ""
        ].joined(separator: "\r\n")
        let entries = parse(M3UParser.decode(Data(text.utf8), assumeUTF8: true))

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].extArtist, "Artist One, Featured Singer")
        XCTAssertEqual(entries[0].extTitle, "First Track (Extended Mix)")
        XCTAssertEqual(entries[0].extDuration, 230)
        XCTAssertEqual(path(entries[1]), "\(dir)/10. SECOND TRACK.flac")
        XCTAssertNil(entries[2].extArtist)
        XCTAssertEqual(entries[2].extTitle, "Some_Artist_-_Third_Track_Extended_Mix_(example.com)")
    }

    func test_parse_traktorStyleExport_cp1252_crlf() {
        var bytes = Array("#EXTM3U\r\n#EXTINF:360,Mot".utf8)
        bytes.append(0xF6) // ö
        bytes += Array("rhead - Ace\r\n/Volumes/USB/Musik/Ace.mp3\r\n#EXTINF:0,\r\n/Volumes/USB/Musik/x.mp3\r\n".utf8)
        let entries = parse(M3UParser.decode(Data(bytes), assumeUTF8: false))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].extArtist, "Motörhead")
        XCTAssertEqual(entries[1].extDuration, 0)
        XCTAssertNil(entries[1].extTitle)
    }

    func test_parse_contentsOf_readsFileAndPicksEncodingByExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M3UParserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m3u = dir.appendingPathComponent("set.m3u")
        try Data([0x47, 0x72, 0xF6, 0x2E, 0x6D, 0x70, 0x33]).write(to: m3u) // "Grö.mp3" CP1252
        let entries = try M3UParser.parse(contentsOf: m3u)
        XCTAssertEqual(entries.map(\.location.fileName), ["Grö.mp3"])
        XCTAssertEqual(path(entries[0]), dir.appendingPathComponent("Grö.mp3").standardizedFileURL.path)
    }
}

final class M3UWriterTests: XCTestCase {

    private func item(_ path: String?, _ seconds: TimeInterval = 447,
                      artist: String = "One Function", title: String = "Ajna") -> M3UWriter.Item {
        M3UWriter.Item(url: path.map { URL(fileURLWithPath: $0) },
                       durationSeconds: seconds, artist: artist, title: title)
    }

    func test_write_absolute_format() {
        let result = M3UWriter.write([
            item("/Volumes/share/_INCOMING Traxx/One_Function_-_Ajna.mp3", 446.6,
                 title: "Ajna (IKØN Remix)")
        ])
        XCTAssertEqual(result.text, """
        #EXTM3U
        #EXTINF:447,One Function - Ajna (IKØN Remix)
        /Volumes/share/_INCOMING Traxx/One_Function_-_Ajna.mp3

        """)
        XCTAssertFalse(result.data.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertFalse(result.text.contains("\r"))
    }

    func test_write_missingEntries_areSkippedAndCounted() {
        let result = M3UWriter.write([item("/a/1.mp3"), item(nil), item("/a/2.mp3")])
        XCTAssertEqual(result.writtenCount, 2)
        XCTAssertEqual(result.skippedMissingCount, 1)
    }

    func test_write_unknownDuration_andMissingTags() {
        let result = M3UWriter.write([item("/a/My Track.mp3", 0, artist: "", title: "")])
        XCTAssertTrue(result.text.contains("#EXTINF:-1,My Track\n"))
    }

    func test_write_newlinesInTags_areFlattened() {
        let result = M3UWriter.write([item("/a/1.mp3", artist: "A\nB", title: "T\r\nU")])
        XCTAssertTrue(result.text.contains("#EXTINF:447,A B - T U\n"))
    }

    func test_write_relative_sameVolume() {
        let playlist = URL(fileURLWithPath: "/Volumes/USB/Playlists/set.m3u8")
        let result = M3UWriter.write([
            item("/Volumes/USB/Playlists/Tracks/a.mp3"),
            item("/Volumes/USB/Musik/b.mp3")
        ], pathStyle: .relative(toPlaylistAt: playlist))
        let paths = result.text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(paths, ["Tracks/a.mp3", "../Musik/b.mp3"])
        XCTAssertEqual(result.absoluteFallbackCount, 0)
    }

    func test_write_relative_otherVolume_fallsBackToAbsolute() {
        let playlist = URL(fileURLWithPath: "/Volumes/USB/set.m3u8")
        let result = M3UWriter.write([
            item("/Volumes/share/a.mp3"),
            item("/Users/dj/Music/b.mp3")
        ], pathStyle: .relative(toPlaylistAt: playlist))
        let paths = result.text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(paths, ["/Volumes/share/a.mp3", "/Users/dj/Music/b.mp3"])
        XCTAssertEqual(result.absoluteFallbackCount, 2)
    }

    func test_write_relative_bootVolume() {
        XCTAssertEqual(
            M3UWriter.relativePath(from: URL(fileURLWithPath: "/Users/dj/Desktop"),
                                   to: URL(fileURLWithPath: "/Users/dj/Music/a.mp3")),
            "../Music/a.mp3")
    }

    // MARK: - Roundtrip

    func test_roundtrip_absolute_preservesOrderDuplicatesAndInfo() {
        let items = [
            item("/Volumes/share/Ü Traxx/b.mp3", 300, artist: "Kölsch", title: "Grey"),
            item("/Volumes/share/a.mp3", 200, artist: "A", title: "One"),
            item("/Volumes/share/Ü Traxx/b.mp3", 300, artist: "Kölsch", title: "Grey")
        ]
        let text = M3UWriter.write(items).text
        let entries = M3UParser.parse(text: text, baseDirectory: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(entries.map(\.location), items.map { .local($0.url!.standardizedFileURL) })
        XCTAssertEqual(entries.map(\.extArtist), ["Kölsch", "A", "Kölsch"])
        XCTAssertEqual(entries.map(\.extTitle), ["Grey", "One", "Grey"])
        XCTAssertEqual(entries.map(\.extDuration), [300, 200, 300])
    }

    func test_roundtrip_relative_resolvesToSameFiles() {
        let playlist = URL(fileURLWithPath: "/Volumes/USB/Playlists/set.m3u8")
        let items = [item("/Volumes/USB/Musik/b.mp3"), item("/Volumes/USB/Playlists/a.mp3")]
        let text = M3UWriter.write(items, pathStyle: .relative(toPlaylistAt: playlist)).text
        let entries = M3UParser.parse(text: text, baseDirectory: playlist.deletingLastPathComponent())
        XCTAssertEqual(entries.map(\.location), items.map { .local($0.url!.standardizedFileURL) })
    }
}
