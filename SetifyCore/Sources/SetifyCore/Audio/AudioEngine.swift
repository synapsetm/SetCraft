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

    var isPlaying: Bool { get }
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var loadedURL: URL? { get }
}

public enum AudioEngineError: Error, Sendable {
    case fileNotLoaded
    case unsupportedFormat
    case engineStartFailed(underlying: String)
}
