import Foundation

/// Diagnostik einer Scan-Runde — nützlich, wenn die Track-Liste leer
/// bleibt und nicht klar ist, ob der Enumerator nichts gefunden oder
/// der Filter alles rausgeworfen hat (typisch für iCloud).
public struct ScanReport: Sendable {
    public let enumeratedCount: Int
    public let audioCount: Int
    public let placeholderCount: Int
    public let firstFew: [String]

    public var summary: String {
        var parts = ["Enumeriert: \(enumeratedCount)", "Audio: \(audioCount)"]
        if placeholderCount > 0 {
            parts.append("iCloud-Platzhalter: \(placeholderCount)")
        }
        if !firstFew.isEmpty {
            parts.append("Items: " + firstFew.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

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
                let (urls, _) = collect(in: folder)
                for url in urls {
                    if Task.isCancelled { break }
                    continuation.yield(trackForURL(url))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Backward-Kompatibilität: Liefert nur die URLs, wirft die Report-Daten
    /// weg. Neuere Aufrufer sollten `collect(in:)` nutzen.
    public static func collectAudioFiles(in folder: URL) -> [URL] {
        collect(in: folder).urls
    }

    /// Synchrones Sammeln aller Audio-URLs unter `folder` PLUS Diagnostik.
    /// macOS-Pakete werden übersprungen, iCloud-Platzhalter (`.<name>.icloud`)
    /// erkannt, in die echte URL aufgelöst und Download angestoßen.
    ///
    /// Verzeichnis wird via `NSFileCoordinator` gelesen, damit iCloud auf
    /// iOS die Listing-Materialisierung erzwingt — sonst gibt der Enumerator
    /// auf einem frisch ausgewählten iCloud-Drive-Ordner gar nichts zurück.
    public static func collect(in folder: URL) -> (urls: [URL], report: ScanReport) {
        var enumerated: [URL] = []
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        coordinator.coordinate(readingItemAt: folder, options: [], error: &coordinatorError) { coordinatedURL in
            let fm = FileManager.default
            // KEIN `.skipsHiddenFiles` — sonst übersehen wir iCloud-Platzhalter
            // (sie sind als hidden markiert). Wir filtern non-Audio unten raus.
            guard let enumerator = fm.enumerator(
                at: coordinatedURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey],
                options: [.skipsPackageDescendants]
            ) else { return }

            for case let url as URL in enumerator {
                enumerated.append(url)
            }
        }

        let fm = FileManager.default
        var audio: [URL] = []
        var placeholderCount = 0
        for url in enumerated {
            let resolved = resolveICloudPlaceholder(url)
            let ext = resolved.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            if url == resolved {
                guard
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }
            } else {
                placeholderCount += 1
                try? fm.startDownloadingUbiquitousItem(at: resolved)
            }
            audio.append(resolved)
        }
        audio.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let firstFew = enumerated.prefix(5).map { $0.lastPathComponent }
        let report = ScanReport(
            enumeratedCount: enumerated.count,
            audioCount: audio.count,
            placeholderCount: placeholderCount,
            firstFew: Array(firstFew)
        )
        return (audio, report)
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
