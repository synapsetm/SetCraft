import Foundation

@MainActor
public protocol AudioEngine: AnyObject {
    func load(url: URL) throws
    func unload()
    func play()
    func pause()
    func seek(to seconds: TimeInterval)

    var rate: Double { get set }
    var pitchCents: Double { get set }
    /// Hält die Tonhöhe beim Ändern der Rate konstant. Ist der Key-Lock aus,
    /// folgt die Tonhöhe dem Tempo wie bei einem Plattenspieler
    /// (`1200·log2(rate)` Cents zusätzlich zu `pitchCents`).
    var keyLock: Bool { get set }

    var isPlaying: Bool { get }
    var position: TimeInterval { get }
    /// Wie `position`, aber auf jedem Zugriff frisch berechnet aus
    /// `lastRenderTime` — ohne die 30-Hz-Timer-Verzögerung. Für die
    /// Waveform-Playhead-Anzeige in einer `TimelineView`, damit der
    /// Cursor synchron zum hörbaren Audio läuft.
    var livePosition: TimeInterval { get }
    var duration: TimeInterval { get }
    var loadedURL: URL? { get }
}

public enum AudioEngineError: Error, Sendable {
    case fileNotLoaded
    case unsupportedFormat
    case engineStartFailed(underlying: String)
}
