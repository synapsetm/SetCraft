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
/// **Was die Kopie kostet.** Beim ERSTEN Zugriff auf einen Track steckt der
/// Download in ihr drin: der Provider liefert sequenziell, und jeder Read
/// blockiert, bis die jeweilige Stelle übertragen ist (am Gerät gemessen:
/// 6–9 s für eine MP3 über Mobilfunk, siehe `SPEC.md` §5c). Genau deshalb
/// kopiert `copyInChunks` häppchenweise — daraus entsteht der Ladefortschritt,
/// den das Dateisystem nicht hergibt. Liegt die Datei bereits lokal, kostet die
/// Kopie Millisekunden.
///
/// Die frühere Lesbarkeitsprobe ist damit entfallen: wer jedes Byte kopiert hat,
/// hat die Vollständigkeit bewiesen. Sie lief einen zweiten Mal durch dieselbe
/// Datei und war der eigentliche Auslöser des Downloads.
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
    ///
    /// Eine Datei mit null Bytes gilt als nicht vorhanden: `AVAudioFile`
    /// beantwortet die sonst mit einem nackten CoreAudio-Fehler, und der
    /// Aufrufer soll in dem Fall die Quelle nehmen statt aufzugeben.
    public func existingCopy(of source: URL) -> URL? {
        guard let target = targetURL(for: source),
              let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0
        else { return nil }
        touch(target.lastPathComponent)
        return target
    }

    /// Wirft die Kopie weg. Für den Fall, dass sie sich nicht öffnen lässt —
    /// dann ist sie unbrauchbar, und der nächste `store` legt sie neu an,
    /// statt die kaputte über die `fileExists`-Abkürzung ewig weiterzureichen.
    public func invalidate(_ source: URL) {
        guard let target = targetURL(for: source) else { return }
        try? FileManager.default.removeItem(at: target)
        let name = target.lastPathComponent
        lock.withLock { recent.removeAll { $0 == name } }
    }

    // MARK: - Schreiben

    /// Legt die Kopie an (oder bestätigt eine vorhandene) und liefert die
    /// spielbare URL. Blockierendes IO — nur von einer Hintergrund-Queue
    /// aufrufen; in SetCraft ist das die Materialisierungs-Queue in
    /// `AVAudioEnginePlayer`.
    ///
    /// Die drei Ausgänge sind bewusst getrennt, weil sie **verschiedene
    /// Konsequenzen** haben:
    ///
    /// - `.cached` — aus der Kopie spielen.
    /// - `.sourceIncomplete` — die Quelle liess sich nicht vollständig lesen.
    ///   Das ist der Fall, für den die Prüfung da ist: von einer halben Datei
    ///   zu spielen ergibt Stille bei laufendem Playhead. Der Load muss **mit
    ///   Meldung** abbrechen.
    /// - `.cacheUnavailable` — der Cache liess sich nicht beschreiben (Platte
    ///   voll, Rechte). Die Quelle ist in Ordnung, also wird von ihr gespielt.
    ///   Ein voller Cache darf die Wiedergabe nicht verhindern.
    ///
    /// Bis 2026-09-20 lieferte die Funktion nur `URL?`, und der Aufrufer machte
    /// aus jedem `nil` einen Ladefehler — damit scheiterte die Wiedergabe auch
    /// dann, wenn bloss der Cache klemmte.
    public enum StoreResult: Sendable {
        case cached(URL)
        case sourceIncomplete(reason: String)
        case cacheUnavailable(reason: String)
    }

    /// `cacheKey` ist die URL, unter der die Kopie später wiedergefunden wird —
    /// normalerweise `source` selbst. Der `NSFileCoordinator` reicht seinem
    /// Closure aber eine **koordinierte** URL, die vom Original abweichen darf;
    /// unter der abgelegt, fände `existingCopy(of: originalURL)` die Kopie nie
    /// wieder und die Wiedergabe hinge doch wieder am FileProvider.
    @discardableResult
    public func store(
        _ source: URL,
        cacheKey: URL? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> StoreResult {
        guard let target = targetURL(for: cacheKey ?? source) else {
            return .cacheUnavailable(reason: "No cache directory available.")
        }
        let fm = FileManager.default

        if fm.fileExists(atPath: target.path) {
            touch(target.lastPathComponent)
            evictBeyondCapacity()
            onProgress?(1)
            return .cached(target)
        }

        clearStaleEntriesOnce()

        // Erst in eine Nachbardatei schreiben, dann umbenennen. Ein
        // abgebrochener Kopiervorgang (App beendet, Platte voll) hinterlässt so
        // keine halbe Datei, die anschliessend als gültige Kopie durchgeht und
        // als Stille abgespielt wird.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)")
        do {
            try copyInChunks(from: source, to: staging, onProgress: onProgress)
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)

            // Wettlauf, kein Fehler: `prefetch` und `prefetchAhead` laufen auf
            // getrennten Queues und holen beim Durchskippen oft DIESELBE Datei —
            // der angetippte Track ist meist der, den die Vorausschau schon
            // lädt. Beide sehen „Ziel existiert nicht", beide kopieren, und der
            // zweite `moveItem` scheitert am inzwischen vorhandenen Ziel. Die
            // fremde Kopie ist genauso gut wie unsere.
            if fm.fileExists(atPath: target.path) {
                touch(target.lastPathComponent)
                evictBeyondCapacity()
                onProgress?(1)
                return .cached(target)
            }

            Self.log.error("""
                Kopie fehlgeschlagen für \(source.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            if case CopyFailure.source(let reason) = error {
                return .sourceIncomplete(reason: reason)
            }
            return .cacheUnavailable(reason: error.localizedDescription)
        }

        touch(target.lastPathComponent)
        evictBeyondCapacity()
        return .cached(target)
    }

    /// Trennt „die Quelle gab nicht alles her" von „der Cache nahm es nicht an".
    /// Nur das Erste darf die Wiedergabe verhindern.
    private enum CopyFailure: Error {
        case source(String)
        case destination(String)
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
        // Die Kopie muss bei gesperrtem Gerät lesbar bleiben — sonst wäre sie
        // genau dann wertlos, wenn sie am meisten gebraucht wird (Track-Wechsel
        // in der Hosentasche). `completeUntilFirstUserAuthentication` ist zwar
        // ohnehin der Standard für neu angelegte Dateien, steht hier aber
        // ausdrücklich: es ist eine Zusicherung dieses Caches, kein Zufall.
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        guard FileManager.default.createFile(
            atPath: staging.path, contents: nil, attributes: attributes
        ) else {
            throw CopyFailure.destination("Could not create the cache file.")
        }
        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw CopyFailure.source(error.localizedDescription)
        }
        do {
            output = try FileHandle(forWritingTo: staging)
        } catch {
            throw CopyFailure.destination(error.localizedDescription)
        }
        defer {
            try? input.close()
            try? output.close()
        }

        var copied: Int64 = 0
        while true {
            let chunk: Data
            do {
                chunk = try input.read(upToCount: Self.chunkBytes) ?? Data()
            } catch {
                throw CopyFailure.source(error.localizedDescription)
            }
            if chunk.isEmpty { break }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                throw CopyFailure.destination(error.localizedDescription)
            }
            copied += Int64(chunk.count)
            if total > 0 {
                onProgress?(min(1, Double(copied) / Double(total)))
            }
        }

        // Grössen-Gegenprobe: ein stillschweigend kurzer Read würde sonst als
        // vollständige Kopie durchgehen und später als Stille abgespielt.
        if total > 0, copied != total {
            throw CopyFailure.source("Only \(copied) of \(total) bytes were readable.")
        }
        onProgress?(1)
    }

    /// Namenspräfix der halbfertigen Kopie. Eigene Konstante, weil der
    /// Aufräumer sie kennen muss — er läuft nebenläufig zu laufenden Kopien.
    private static let stagingPrefix = "staging-"

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
            // `staging-…` gehört einer Kopie, die in diesem Moment läuft: die
            // beiden Queues kopieren nebenläufig, und der Aufräumer sieht die
            // halbfertige Datei der jeweils anderen. Sie hier wegzuräumen liess
            // deren `moveItem` ins Leere laufen.
            if entry.lastPathComponent.hasPrefix(Self.stagingPrefix) { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
