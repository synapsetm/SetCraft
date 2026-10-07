import XCTest
@testable import SetCraftCore

/// Der Ordner-Scan ist bewusst **flach**: eine Quelle zeigt genau ihren
/// eigenen Ordner. Vorher lief er rekursiv, wodurch ein Sammelordner hunderte
/// Tracks aus Unterverzeichnissen in die Liste zog.
final class FolderScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub/deeper")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try touch(root.appendingPathComponent("top.mp3"))
        try touch(root.appendingPathComponent("notes.txt"))          // kein Audio
        try touch(root.appendingPathComponent("sub/nested.mp3"))
        try touch(sub.appendingPathComponent("deep.flac"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    func test_collect_findsOnlyFilesDirectlyInTheFolder() {
        let (urls, _) = FolderScanner.collect(in: root)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["top.mp3"])
    }

    func test_collect_inSubfolder_findsThatFolderOnly() {
        let (urls, _) = FolderScanner.collect(in: root.appendingPathComponent("sub"))
        XCTAssertEqual(urls.map(\.lastPathComponent), ["nested.mp3"])
    }

    /// Sibling-Temps des Tag-Writes und AppleDouble-Dateien vom NAS dürfen
    /// nicht als Track erscheinen — sie verschwinden oder sind kein Audio.
    func test_collect_skipsHiddenFiles() throws {
        try touch(root.appendingPathComponent(".setcraft-\(UUID().uuidString)-top.mp3"))
        try touch(root.appendingPathComponent("._top.mp3"))
        let (urls, _) = FolderScanner.collect(in: root)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["top.mp3"])
    }

    /// iCloud-Platzhalter sind ebenfalls versteckt, werden aber auf den
    /// echten Namen aufgelöst und müssen in der Liste bleiben.
    func test_collect_keepsICloudPlaceholders() throws {
        try touch(root.appendingPathComponent(".remote.mp3.icloud"))
        let (urls, report) = FolderScanner.collect(in: root)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["remote.mp3", "top.mp3"])
        XCTAssertEqual(report.placeholderCount, 1)
    }

    func test_collect_skipsNonAudioExtensions() {
        let (urls, _) = FolderScanner.collect(in: root)
        XCTAssertFalse(urls.contains { $0.pathExtension == "txt" })
    }
}
