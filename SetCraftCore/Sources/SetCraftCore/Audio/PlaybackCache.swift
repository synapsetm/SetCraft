import CryptoKit
import Foundation
import OSLog

/// Hält eine lokale Kopie der Datei, aus der gerade gespielt wird — und der,
/// die als nächste dran ist. Mehr nicht: höchstens zwei Dateien gleichzeitig.
///
/// **Warum überhaupt kopieren.** Bis 2026-09-19 las die Engine direkt von der
/// Quell-URL. Bei einer Quelle über den FileProvider (iCloud, NAS/SMB aus der
/// Files-App) hängt damit die Wiedergabe am Provider: bricht das Netz weg,
/// stirbt die SMB-Session, das offene Handle wird ungültig, die Lese-Aufrufe
/// schlagen fehl — und `AVAudioPlayerNode` zählt seine Sample-Position trotzdem
/// weiter. Ergebnis: Stille bei laufendem Playhead, ohne jede Meldung. Mit einer
/// eigenen Kopie ist der Provider aus dem Wiedergabe-Pfad heraus.
///
/// **Warum das billig ist.** Wenn ein Track spielt, liegt er längst lokal — der
/// Provider hat ihn beim Materialisieren vollständig geholt, sonst hätte die
/// Tail-Probe in `AVAudioEnginePlayer` ihn abgelehnt. Die Kopie ist also
/// lokal → lokal und kostet bei einer MP3 Millisekunden.
///
/// **Abgrenzung zur Projektregel.** SetCraft kopiert die *Bibliothek* nicht in
/// die App-Sandbox, das bleibt so. Dies hier ist ein flüchtiger
/// Wiedergabe-Puffer von maximal zwei Dateien in `Caches/`, vom Nutzer am
/// 2026-09-19 ausdrücklich so entschieden — keine Zweitkopie der Sammlung.
public final class PlaybackCache: @unchecked Sendable {

    public static let shared = PlaybackCache()

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "PlaybackCache")

    /// Höchstzahl gehaltener Kopien: der laufende Track und der vorausgeholte.
    private static let capacity = 2

    private let lock = NSLock()
    /// Zuletzt benutzte Cache-Dateinamen, jüngste zuerst. Das ist die
    /// Verdrängungsordnung — bei Kapazität 2 reicht eine Liste, kein Heap.
    private var recent: [String] = []
    private var didClearStaleEntries = false

    private lazy var directory: URL? = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = caches.appendingPathComponent("playback", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            Self.log.error("Cache-Verzeichnis nicht anlegbar: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    private init() {}

    // MARK: - Entscheidung

    /// Ob diese Quelle überhaupt kopiert werden soll.
    ///
    /// Eine Datei, die schon auf lokalem Speicher liegt, zu kopieren wäre reine
    /// Verschwendung — sie kann nicht wegen eines Netzausfalls verschwinden.
    /// Die Prüfung unterscheidet sich je Plattform, weil sich der Problemfall
    /// unterschiedlich zeigt:
    ///
    /// - **iOS:** alles, was ausserhalb des App-Containers liegt, kommt über den
    ///   FileProvider — auch ein SMB-Share aus der Files-App. `volumeIsLocal`
    ///   hilft hier nicht, der Provider präsentiert seine Dateien auf der
    ///   lokalen Platte und meldet `true`.
    /// - **macOS:** die Bibliothek liegt im Home des Nutzers und ist lokal; das
    ///   Problem sind gemountete Netz-Volumes. Dort greift `volumeIsLocal`
    ///   genau richtig, und wir kopieren nicht bei jedem Track im Home.
    public func shouldCache(_ source: URL) -> Bool {
        #if os(iOS)
        let container = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let path = source.standardizedFileURL.path
        return !path.hasPrefix(container)
        #else
        let values = try? source.resourceValues(forKeys: [.volumeIsLocalKey])
        // Keine Auskunft → nicht kopieren. Im Zweifel das bisherige Verhalten.
        return values?.volumeIsLocal == false
        #endif
    }

    // MARK: - Lesen

    /// Die bereits vorhandene Kopie, falls es eine gibt. Kostet einen `stat`,
    /// nichts weiter — darum auch vom MainActor aus unbedenklich, was
    /// `AVAudioEnginePlayer.load` ausnutzt.
    public func existingCopy(of source: URL) -> URL? {
        guard let target = targetURL(for: source),
              FileManager.default.fileExists(atPath: target.path)
        else { return nil }
        touch(target.lastPathComponent)
        return target
    }

    // MARK: - Schreiben

    /// Legt die Kopie an (oder bestätigt eine vorhandene) und liefert die
    /// spielbare URL. Blockierendes IO — nur von einer Hintergrund-Queue
    /// aufrufen; in SetCraft ist das die Materialisierungs-Queue in
    /// `AVAudioEnginePlayer`.
    ///
    /// Schlägt das Kopieren fehl (kein Platz, Rechte), wird das geloggt und
    /// `nil` geliefert: der Aufrufer spielt dann wie früher direkt von der
    /// Quelle. Ein voller Cache darf die Wiedergabe nicht verhindern.
    @discardableResult
    public func store(_ source: URL, onProgress: (@Sendable (Double) -> Void)? = nil) -> URL? {
        guard let target = targetURL(for: source) else { return nil }
        let fm = FileManager.default

        if fm.fileExists(atPath: target.path) {
            touch(target.lastPathComponent)
            evictBeyondCapacity()
            onProgress?(1)
            return target
        }

        clearStaleEntriesOnce()

        // Erst in eine Nachbardatei schreiben, dann umbenennen. Ein
        // abgebrochener Kopiervorgang (App beendet, Platte voll) hinterlässt so
        // keine halbe Datei, die anschliessend als gültige Kopie durchgeht und
        // als Stille abgespielt wird.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString)")
        do {
            try copyInChunks(from: source, to: staging, onProgress: onProgress)
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            Self.log.error("""
                Kopie fehlgeschlagen für \(source.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }

        touch(target.lastPathComponent)
        evictBeyondCapacity()
        return target
    }

    /// Kopiert häppchenweise statt mit `FileManager.copyItem` — und das ist der
    /// ganze Zweck: bei einer Quelle über den FileProvider lädt jeder Read genau
    /// so lange, bis der Download seine Stelle erreicht hat (am Gerät gemessen:
    /// ein Read in der Dateimitte wartet 6–8s, einer am Ende nochmal so lange).
    /// Kehrt ein Häppchen zurück, sind seine Bytes übertragen — damit ist der
    /// Fortschritt bekannt, den weder `copyItem` noch das Dateisystem preisgeben
    /// (`totalFileAllocatedSize` steht von Anfang an auf 100 %).
    ///
    /// Ersetzt zugleich die frühere Lesbarkeitsprobe: wer jedes Byte kopiert
    /// hat, hat die Vollständigkeit bewiesen. Vorher lief die Datei zweimal
    /// durch — einmal für die Probe, einmal für die Kopie.
    private func copyInChunks(
        from source: URL,
        to staging: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws {
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: staging)
        defer {
            try? input.close()
            try? output.close()
        }

        var copied: Int64 = 0
        while true {
            let chunk = try input.read(upToCount: Self.chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            if total > 0 {
                onProgress?(min(1, Double(copied) / Double(total)))
            }
        }

        // Grössen-Gegenprobe: ein stillschweigend kurzer Read würde sonst als
        // vollständige Kopie durchgehen und später als Stille abgespielt.
        if total > 0, copied != total {
            throw CocoaError(.fileReadCorruptFile)
        }
        onProgress?(1)
    }

    /// 256 KB pro Häppchen. Gross genug, dass der Overhead nicht auffällt,
    /// klein genug für eine flüssige Fortschrittsanzeige — bei 10 MB sind das
    /// rund 40 Aktualisierungen.
    private static let chunkBytes = 256 * 1024

    // MARK: - Intern

    /// Deterministischer Dateiname aus dem Quellpfad. Die Endung bleibt
    /// erhalten — manche Decoder-Pfade in AVFoundation schauen darauf.
    private func targetURL(for source: URL) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
        let name = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        let ext = source.pathExtension
        let filename = ext.isEmpty ? name : "\(name).\(ext)"
        return directory.appendingPathComponent(filename)
    }

    private func touch(_ filename: String) {
        lock.withLock {
            recent.removeAll { $0 == filename }
            recent.insert(filename, at: 0)
        }
    }

    /// Alles ausser den jüngsten `capacity` Einträgen löschen.
    private func evictBeyondCapacity() {
        let doomed: [String] = lock.withLock {
            guard recent.count > Self.capacity else { return [] }
            let extra = Array(recent[Self.capacity...])
            recent = Array(recent[..<Self.capacity])
            return extra
        }
        guard let directory, !doomed.isEmpty else { return }
        for name in doomed {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Reste einer früheren Sitzung einmalig wegräumen. `Caches/` überlebt
    /// Neustarts, die `recent`-Liste nicht — ohne das wüchse das Verzeichnis
    /// über die Sitzungen hinweg, obwohl höchstens zwei Dateien gebraucht werden.
    private func clearStaleEntriesOnce() {
        let shouldClear: Bool = lock.withLock {
            guard !didClearStaleEntries else { return false }
            didClearStaleEntries = true
            return true
        }
        guard shouldClear, let directory else { return }
        let keep = Set(lock.withLock { recent })
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where !keep.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
