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
                    continuation.yield(trackForURL(url))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchrones Sammeln aller Audio-URLs unter `folder`. macOS-Pakete
    /// (z. B. Logic-Sessions) werden übersprungen. iCloud-Platzhalter
    /// (`.<name>.icloud`) werden erkannt, in die echte URL aufgelöst und
    /// der Download wird angestoßen — sonst sähe die App den Ordner leer,
    /// wenn die Files noch nicht aufs Gerät geladen sind.
    public static func collectAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        // KEIN `.skipsHiddenFiles` — sonst übersehen wir iCloud-Platzhalter
        // (sie sind als hidden markiert). Wir filtern non-Audio unten raus.
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let resolved = resolveICloudPlaceholder(url)
            let ext = resolved.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            if url == resolved {
                // Echte Datei — regularFile-Check, sonst raus (Ordner, Symlink).
                guard
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }
            } else {
                // Platzhalter → Download triggern, die echte URL nehmen wir
                // ohne weitere Resource-Checks (Datei existiert noch nicht).
                try? fm.startDownloadingUbiquitousItem(at: resolved)
            }
            result.append(resolved)
        }
        result.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }

    /// iCloud-Platzhalter heißen `.<originalname>.icloud` und sind hidden.
    /// Diese Methode gibt die echte URL zurück (Punkt-Präfix und
    /// `.icloud`-Suffix entfernt), bei normalen URLs passiert nichts.
    private static func resolveICloudPlaceholder(_ url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return url }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    /// Baut den Track für eine URL. Files, die noch in iCloud liegen und
    /// nicht lokal sind, bekommen einen Platzhalter-Track aus dem
    /// Dateinamen — TagLib kann un-downloaded Files nicht öffnen, würde
    /// die Datei in der Liste sonst verschlucken. Beim nächsten Scan
    /// (Datei dann lokal) werden die echten Tags geladen.
    private static func trackForURL(_ url: URL) -> Track {
        guard isLocallyAvailable(url) else { return Track(url: url) }
        return (try? TagReader.read(url: url)) ?? Track(url: url)
    }

    /// `false`, wenn die Datei in iCloud liegt und noch nicht (oder
    /// nicht vollständig) heruntergeladen wurde. Für non-iCloud immer `true`.
    private static func isLocallyAvailable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard let values, values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }
}
