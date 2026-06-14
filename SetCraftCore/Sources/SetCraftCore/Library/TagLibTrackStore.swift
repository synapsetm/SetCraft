import Foundation
import SetCraftCoreObjC

/// `TrackStore`-Implementierung über die TagLib-Bridge. Schreibt Tag-
/// Änderungen atomar (Kopie nach Temp → TagLib → atomic replace) und
/// serialisiert alle Schreibzugriffe (durch den Actor selbst).
public actor TagLibTrackStore: TrackStore {

    public enum StoreError: LocalizedError {
        case fileInUse
        case bridgeFailed(URL, underlying: Error?)
        case fileSystem(URL, stage: String, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .fileInUse:
                return "File is currently active in the player — write skipped."
            case .bridgeFailed(let url, let underlying):
                return "TagLib could not write \(url.lastPathComponent): \(underlying?.localizedDescription ?? "unknown")"
            case .fileSystem(let url, let stage, let underlying):
                let ns = underlying as NSError
                return "Filesystem error for \(url.lastPathComponent) at \(stage): \(ns.localizedDescription) [\(ns.domain) #\(ns.code)]"
            }
        }
    }

    private var activeURL: URL?

    public init() {}

    public func setActiveTrack(_ url: URL?) {
        activeURL = url
    }

    public func save(_ track: Track) async throws {
        try await save(track, force: false)
    }

    /// Schreibt Tags. Wenn `force == true`, wird der Active-Track-Guard
    /// übersprungen — gedacht für explizite User-Edits aus dem Player
    /// (TagEditSheet, Rating-Tap), die sonst hängen blieben, weil der
    /// gerade abgespielte Track aktiv ist. `replaceItemAt` ist unter
    /// Unix-Semantik sicher: AVAudioFile hält das alte inode via fd
    /// weiterhin offen, der Pfad zeigt nach dem atomaren Swap aufs neue.
    public func save(_ track: Track, force: Bool) async throws {
        if !force, let active = activeURL, active == track.url {
            throw StoreError.fileInUse
        }

        let original = track.url
        let fm = FileManager.default

        // Sibling-Temp im selben Ordner wie das Original. Bewusst KEIN
        // `.itemReplacementDirectory` mehr: dessen `(A Document Being Saved …)`-
        // Unterordner liegt auf SMB-Mounts zwar physisch am richtigen Ort,
        // wird aber von der Sandbox-Extension der gewählten Quelle in manchen
        // Konstellationen nicht abgedeckt — Schreibversuche schlagen dann mit
        // EPERM/ENOTSUP fehl. Ein Dot-File neben dem Original bleibt
        // garantiert innerhalb des Security-Scope.
        let parent = original.deletingLastPathComponent()
        let tempFile = parent.appendingPathComponent(
            ".setcraft-\(UUID().uuidString)-\(original.lastPathComponent)"
        )
        defer { try? fm.removeItem(at: tempFile) }

        do {
            try fm.copyItem(at: original, to: tempFile)
        } catch {
            throw StoreError.fileSystem(original, stage: "copyItem", underlying: error)
        }

        let comment = RatingPrefix.format(track.rating, rest: track.comment)
        let bpmString = track.bpm.map(Self.formatBPM) ?? ""
        let keyString = track.key?.description ?? ""

        do {
            try SetCraftTagBridge.writeTags(
                atPath: tempFile.path,
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                comment: comment,
                bpm: bpmString,
                initialKey: keyString,
                label: track.label
            )
        } catch {
            throw StoreError.bridgeFailed(original, underlying: error)
        }

        try Self.atomicReplace(original: original, with: tempFile, fm: fm)
    }

    /// Ersetzt `original` durch `tempFile`. Versucht zuerst den atomaren
    /// `replaceItemAt`-Pfad (APFS, lokale Volumes) und fällt bei Fehlern auf
    /// einen Rename-Über-Backup-Pfad zurück, der auf SMB-Mounts zuverlässig
    /// funktioniert. `replaceItemAt` schlägt auf SMB regelmässig fehl, weil
    /// es interne `setattrlist`-/xattr-Operationen macht, die der SMB-Server
    /// mit ENOTSUP quittiert.
    private static func atomicReplace(
        original: URL,
        with tempFile: URL,
        fm: FileManager
    ) throws {
        do {
            _ = try fm.replaceItemAt(original, withItemAt: tempFile)
            return
        } catch {
            // Fallback: rename(original → backup) + rename(temp → original) +
            // remove(backup). Nicht atomar, aber überlebt jeden Zwischenschritt
            // ohne Datenverlust:
            //   - backup bleibt liegen, falls move scheitert
            //   - falls remove(backup) scheitert, ist die Datei trotzdem korrekt
            let backup = original.appendingPathExtension("setcraft-bak-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: original, to: backup)
            } catch let moveError {
                throw StoreError.fileSystem(original, stage: "replaceItemAt+backup", underlying: moveError)
            }
            do {
                try fm.moveItem(at: tempFile, to: original)
            } catch let renameError {
                // Original aus Backup wiederherstellen, sonst verliert der
                // Nutzer die Datei.
                try? fm.moveItem(at: backup, to: original)
                throw StoreError.fileSystem(original, stage: "replaceItemAt+rename", underlying: renameError)
            }
            try? fm.removeItem(at: backup)
        }
    }

    private static func formatBPM(_ bpm: Double) -> String {
        bpm.rounded() == bpm ? String(Int(bpm)) : String(format: "%.1f", bpm)
    }
}
