import Foundation
import SetCraftCoreObjC

/// `TrackStore`-Implementierung über die TagLib-Bridge. Schreibt Tag-
/// Änderungen atomar (Kopie nach Temp → TagLib → atomic replace) und
/// serialisiert alle Schreibzugriffe (durch den Actor selbst).
public actor TagLibTrackStore: TrackStore {

    public enum StoreError: LocalizedError {
        case fileInUse
        case bridgeFailed(URL, underlying: Error?)
        case fileSystem(URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .fileInUse:
                return "File is currently active in the player — write skipped."
            case .bridgeFailed(let url, let underlying):
                return "TagLib could not write \(url.lastPathComponent): \(underlying?.localizedDescription ?? "unknown")"
            case .fileSystem(let url, let underlying):
                return "Filesystem error for \(url.lastPathComponent): \(underlying.localizedDescription)"
            }
        }
    }

    private var activeURL: URL?

    public init() {}

    public func setActiveTrack(_ url: URL?) {
        activeURL = url
    }

    public func save(_ track: Track) async throws {
        if let active = activeURL, active == track.url {
            throw StoreError.fileInUse
        }

        let original = track.url
        let fm = FileManager.default

        let tempDir: URL
        do {
            tempDir = try fm.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: original,
                create: true
            )
        } catch {
            throw StoreError.fileSystem(original, underlying: error)
        }
        defer { try? fm.removeItem(at: tempDir) }

        let tempFile = tempDir.appendingPathComponent(original.lastPathComponent)
        do {
            try fm.copyItem(at: original, to: tempFile)
        } catch {
            throw StoreError.fileSystem(original, underlying: error)
        }

        let comment = RatingPrefix.format(track.rating, rest: track.comment)
        let bpmString = track.bpm.map(Self.formatBPM) ?? ""
        let keyString = track.key?.description ?? ""

        do {
            try SetifyTagBridge.writeTags(
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

        do {
            _ = try fm.replaceItemAt(original, withItemAt: tempFile)
        } catch {
            throw StoreError.fileSystem(original, underlying: error)
        }
    }

    private static func formatBPM(_ bpm: Double) -> String {
        bpm.rounded() == bpm ? String(Int(bpm)) : String(format: "%.1f", bpm)
    }
}
