import XCTest
@testable import SetCraftCore

final class RelinkIndexTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func test_tailMatch_beatsPlainFileName() {
        let index = RelinkIndex(files: [
            url("/Volumes/share/Sets/2026/intro.mp3"),
            url("/Volumes/share/Archiv/2025/intro.mp3")
        ])
        let hits = index.candidates(for: .local(url("/Users/dj/Music/Sets/2026/intro.mp3")))
        XCTAssertEqual(hits.map(\.path), ["/Volumes/share/Sets/2026/intro.mp3"])
    }

    func test_twoSegmentTail_whenThreeDoNotMatch() {
        let index = RelinkIndex(files: [
            url("/Volumes/share/A/Sets/intro.mp3"),
            url("/Volumes/share/B/Other/intro.mp3")
        ])
        let hits = index.candidates(for: .local(url("/old/X/Sets/intro.mp3")))
        XCTAssertEqual(hits.map(\.path), ["/Volumes/share/A/Sets/intro.mp3"])
    }

    func test_fileNameOnly_multipleHits_areAmbiguous() {
        let index = RelinkIndex(files: [url("/a/x/t.mp3"), url("/b/y/t.mp3")])
        XCTAssertEqual(index.candidates(for: .local(url("/c/z/t.mp3"))).count, 2)
    }

    func test_normalizedName_matchesNFDAndCase() {
        let nfd = "Ko\u{0308}lsch - Grey.MP3"          // ö zerlegt, Endung gross
        let index = RelinkIndex(files: [url("/Volumes/share/\(nfd)")])
        let hits = index.candidates(for: .local(url("/old/Kölsch - Grey.mp3")))
        XCTAssertEqual(hits.count, 1)
    }

    func test_foreignWindowsPath_usesFileNameAndTail() {
        let index = RelinkIndex(files: [url("/Volumes/share/Music/Track One.mp3")])
        let hits = index.candidates(for: .foreign(path: "C:/Users/dj/Music/Track One.mp3"))
        XCTAssertEqual(hits.count, 1)
    }

    func test_remote_neverMatches() {
        let index = RelinkIndex(files: [url("/a/stream.mp3")])
        XCTAssertEqual(index.candidates(for: .remote(URL(string: "https://x/stream.mp3")!)), [])
    }

    func test_duplicateInputFiles_countOnce() {
        let index = RelinkIndex(files: [url("/a/t.mp3"), url("/a/./t.mp3")])
        XCTAssertEqual(index.candidates(for: .local(url("/b/t.mp3"))).count, 1)
    }
}

final class PlaylistResolverTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func entry(_ line: String, _ index: Int = 1) -> PlaylistEntry {
        let base = url("/Volumes/share/Playlists")
        return PlaylistEntry(index: index, rawLine: line,
                             location: M3UParser.location(for: line, baseDirectory: base))
    }

    /// Dateisystem-Attrappe: was in `existing` steht, gibt es; was in
    /// `denied` steht, gibt es, aber die Sandbox verweigert.
    private func probe(existing: Set<String> = [], denied: Set<String> = []) -> (URL) -> FileProbeResult {
        { url in
            if existing.contains(url.path) { return .exists }
            if denied.contains(url.path) { return .noPermission }
            return .notFound
        }
    }

    private func status(_ line: String,
                        roots: [String] = ["/Volumes/share/Musik"],
                        files: [String] = [],
                        links: [String: String] = [:],
                        canRequestAccess: Bool = true,
                        existing: Set<String> = [],
                        denied: Set<String> = []) -> PlaylistEntryStatus {
        let context = PlaylistResolver.Context(
            grantedRoots: roots.map(url),
            relinkIndex: RelinkIndex(files: files.map(url)),
            storedLinks: links,
            canRequestAccess: canRequestAccess)
        return PlaylistResolver.resolve([entry(line)], context: context,
                                        probe: probe(existing: existing, denied: denied))[0].status
    }

    func test_coveredAndExisting_isResolved() {
        let path = "/Volumes/share/Musik/Sub/a.mp3"
        XCTAssertEqual(status(path, existing: [path]), .resolved(url(path)))
    }

    func test_relativePath_coveredAndExisting_isResolved() {
        let path = "/Volumes/share/Musik/a.mp3"
        XCTAssertEqual(status("../Musik/a.mp3", existing: [path]), .resolved(url(path)))
    }

    func test_uncovered_existing_isNoAccess() {
        let path = "/Volumes/other/a.mp3"
        XCTAssertEqual(status(path, existing: [path]), .noAccess(url(path)))
    }

    func test_uncovered_permissionDenied_isNoAccess() {
        let path = "/Volumes/other/a.mp3"
        XCTAssertEqual(status(path, denied: [path]), .noAccess(url(path)))
    }

    func test_uncovered_onIOS_goesStraightToRelink() {
        let mac = "/Volumes/share/_In/a.mp3"
        let found = "/private/var/mobile/Share/_In/a.mp3"
        XCTAssertEqual(
            status(mac, roots: ["/private/var/mobile/Share"], files: [found],
                   canRequestAccess: false, denied: [mac]),
            .relinked(url(found)))
    }

    func test_missing_withSingleCandidate_isRelinked() {
        let found = "/Volumes/share/Musik/Neu/a.mp3"
        XCTAssertEqual(status("/Volumes/share/Musik/Alt/a.mp3", files: [found]), .relinked(url(found)))
    }

    func test_missing_withSeveralCandidates_isAmbiguous() {
        let files = ["/Volumes/share/Musik/x/a.mp3", "/Volumes/share/Musik/y/a.mp3"]
        XCTAssertEqual(status("/old/z/a.mp3", files: files), .ambiguous(files.map(url)))
    }

    func test_missing_withoutCandidate_isMissing() {
        XCTAssertEqual(status("/old/a.mp3"), .missing)
    }

    func test_windowsPath_relinksByName() {
        let found = "/Volumes/share/Musik/a.mp3"
        XCTAssertEqual(status("C:\\Music\\a.mp3", files: [found]), .relinked(url(found)))
    }

    func test_http_isUnsupported() {
        XCTAssertEqual(status("https://example.com/a.mp3"), .unsupported)
    }

    func test_storedLink_winsWhenStillValid() {
        let stored = "/Volumes/share/Musik/chosen.mp3"
        XCTAssertEqual(
            status("/old/a.mp3", files: ["/Volumes/share/Musik/x/a.mp3", "/Volumes/share/Musik/y/a.mp3"],
                   links: ["/old/a.mp3": stored], existing: [stored]),
            .relinked(url(stored)))
    }

    func test_storedLink_ignoredWhenFileGone() {
        XCTAssertEqual(status("/old/a.mp3", links: ["/old/a.mp3": "/Volumes/share/Musik/gone.mp3"]),
                       .missing)
    }

    func test_duplicates_keepOrder() {
        let path = "/Volumes/share/Musik/a.mp3"
        let context = PlaylistResolver.Context(grantedRoots: [url("/Volumes/share/Musik")],
                                               relinkIndex: RelinkIndex(files: []))
        let resolved = PlaylistResolver.resolve([entry(path, 1), entry("/x.mp3", 2), entry(path, 3)],
                                                context: context, probe: probe(existing: [path]))
        XCTAssertEqual(resolved.map(\.entry.index), [1, 2, 3])
        XCTAssertEqual(resolved.map(\.status.fileURL), [url(path), nil, url(path)])
    }

    // MARK: - Gemeinsamer Ordner

    func test_commonAncestor() {
        XCTAssertEqual(PlaylistResolver.commonAncestor(of: [
            url("/Volumes/share/04_Audio/A/x.mp3"),
            url("/Volumes/share/04_Audio/B/C/y.mp3")
        ])?.path, "/Volumes/share/04_Audio")
        XCTAssertEqual(PlaylistResolver.commonAncestor(of: [url("/Volumes/share/A/x.mp3")])?.path,
                       "/Volumes/share/A")
        XCTAssertEqual(PlaylistResolver.commonAncestor(of: [url("/a/x.mp3"), url("/b/y.mp3")])?.path, "/")
        XCTAssertNil(PlaylistResolver.commonAncestor(of: []))
    }

    // MARK: - Echtes Dateisystem

    func test_fileSystemProbe() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mp3")
        try Data().write(to: file)

        XCTAssertEqual(PlaylistResolver.fileSystemProbe(file), .exists)
        XCTAssertEqual(PlaylistResolver.fileSystemProbe(dir.appendingPathComponent("b.mp3")), .notFound)
        XCTAssertEqual(PlaylistResolver.fileSystemProbe(dir), .notFound, "Ordner sind kein Track")
    }

    func test_load_readsAndResolvesOffMainActor() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadTests-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.mp3"))
        let m3u = dir.appendingPathComponent("set.m3u8")
        try Data("#EXTM3U\n#EXTINF:1,A - B\na.mp3\nfehlt.mp3\n".utf8).write(to: m3u)

        let resolved = try await PlaylistResolver.load(
            playlistAt: m3u,
            context: .init(grantedRoots: [dir], relinkIndex: RelinkIndex(files: [])))
        XCTAssertEqual(resolved.map(\.status), [.resolved(dir.appendingPathComponent("a.mp3").standardizedFileURL), .missing])
    }
}

final class PlaylistLinkStoreTests: XCTestCase {

    func test_links_roundtrip_andCascadeWithFolder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistLinkTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try DatabaseService(databaseURL: dir.appendingPathComponent("db.sqlite"))

        let folder = FolderRecord(url: URL(fileURLWithPath: "/Volumes/share/set.m3u8"),
                                  name: "set", bookmarkData: Data([1]))
        try await db.saveFolder(folder)
        try await db.savePlaylistLink(PlaylistLink(playlistID: folder.id, originalLine: "/old/a.mp3",
                                                   resolvedURL: URL(fileURLWithPath: "/new/a.mp3")))
        try await db.savePlaylistLink(PlaylistLink(playlistID: folder.id, originalLine: "/old/a.mp3",
                                                   resolvedURL: URL(fileURLWithPath: "/newer/a.mp3")))

        let links = try await db.playlistLinks(playlistID: folder.id)
        XCTAssertEqual(links, ["/old/a.mp3": "/newer/a.mp3"])

        try await db.deleteFolder(id: folder.id)
        let afterDelete = try await db.playlistLinks(playlistID: folder.id)
        XCTAssertEqual(afterDelete, [:])
    }
}
