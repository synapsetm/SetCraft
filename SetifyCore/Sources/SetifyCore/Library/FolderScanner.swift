import Foundation

/// Rekursiver Ordner-Scan auf Audiodateien. Liest pro Datei die Tags
/// (TagReader) auf einem Hintergrund-Task und liefert die `Track`-Werte als
/// `AsyncStream`, damit die UI Reihen sofort beim Eintreffen anzeigen kann.
public enum FolderScanner {

    /// Dateiendungen, die TagLib zuverlässig verarbeitet und die wir scannen.
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "aac", "alac",
        "flac", "ogg", "oga", "opus",
        "wav", "aif", "aiff", "aifc"
    ]

    public static func scan(folder: URL) -> AsyncStream<Track> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let urls = collectAudioFiles(in: folder)
                for url in urls {
                    if Task.isCancelled { break }
                    if let track = try? TagReader.read(url: url) {
                        continuation.yield(track)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchrones Sammeln aller Audio-URLs unter `folder`. Versteckte Dateien
    /// und macOS-Pakete (z. B. Logic-Sessions) werden übersprungen.
    public static func collectAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            result.append(url)
        }
        result.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}
