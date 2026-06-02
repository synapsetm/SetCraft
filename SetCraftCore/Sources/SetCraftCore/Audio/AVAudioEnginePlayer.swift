import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class AVAudioEnginePlayer: AudioEngine {

    // MARK: - Public observable state

    public private(set) var isPlaying: Bool = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var loadedURL: URL?

    // Stored properties, damit @Observable die Änderungen mitbekommt und
    // SwiftUI-Views (Chips, Slider, Anzeige) sich erneuern. didSet syncht
    // den geklemmten Wert auf den nicht-observable AVAudioUnitTimePitch-Knoten.
    public var rate: Double = 1.0 {
        didSet {
            let clamped = max(0.5, min(2.0, rate))
            timePitch.rate = Float(clamped)
            if rate != clamped { rate = clamped }
        }
    }

    public var pitchCents: Double = 0 {
        didSet {
            let clamped = max(-2400, min(2400, pitchCents))
            timePitch.pitch = Float(clamped)
            if pitchCents != clamped { pitchCents = clamped }
        }
    }

    // MARK: - Private audio graph

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var audioFile: AVAudioFile?
    private var seekFrame: AVAudioFramePosition = 0
    private var positionTimer: Timer?

    /// Jeder Aufruf von `scheduleFromSeekFrame()` erhöht den Zähler. Die
    /// Completion-Closure speichert ihren Generation-Wert und vergleicht ihn
    /// in handlePlaybackFinished. So lehnen wir Callbacks ab, die zum
    /// abgebrochenen alten Schedule gehören (sonst springt der Playhead
    /// nach einem Seek während der Wiedergabe wieder an den Trackanfang
    /// zurück, weil der alte Buffer als "fertig abgespielt" gemeldet wird).
    private var scheduleGeneration: Int = 0

    public init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    // MARK: - AudioEngine

    public func load(url: URL) throws {
        stopPlayback()

        let file = try AVAudioFile(forReading: url)
        audioFile = file
        loadedURL = url
        duration = TimeInterval(file.length) / file.processingFormat.sampleRate
        seekFrame = 0
        position = 0

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)

        if !engine.isRunning {
            try startEngine()
        }
        scheduleFromSeekFrame()
    }

    public func unload() {
        stopPlayback()
        audioFile = nil
        loadedURL = nil
        duration = 0
        position = 0
        seekFrame = 0
    }

    public func play() {
        guard audioFile != nil else { return }
        if !engine.isRunning {
            do { try startEngine() } catch { return }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaying = true
        startPositionTimer()
    }

    public func pause() {
        guard isPlaying else { return }
        if let frame = currentFrame() {
            seekFrame = frame
            position = TimeInterval(frame) / sampleRate
        }
        playerNode.stop()
        isPlaying = false
        stopPositionTimer()
        scheduleFromSeekFrame()
    }

    public func seek(to seconds: TimeInterval) {
        guard let file = audioFile else { return }
        let clamped = max(0, min(duration, seconds))
        seekFrame = AVAudioFramePosition(clamped * file.processingFormat.sampleRate)
        position = clamped

        let wasPlaying = isPlaying
        playerNode.stop()
        scheduleFromSeekFrame()
        if wasPlaying {
            if !engine.isRunning { try? startEngine() }
            playerNode.play()
        }
    }

    // MARK: - Internals

    private var sampleRate: Double {
        audioFile?.processingFormat.sampleRate ?? 44_100
    }

    private func startEngine() throws {
        do {
            try engine.start()
        } catch {
            throw AudioEngineError.engineStartFailed(underlying: error.localizedDescription)
        }
    }

    private func stopPlayback() {
        playerNode.stop()
        isPlaying = false
        stopPositionTimer()
    }

    private func scheduleFromSeekFrame() {
        guard let file = audioFile else { return }
        let startFrame = seekFrame
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stale-Callback verwerfen: gehört zu einem Schedule,
                // den ein späteres seek/pause/load längst abgebrochen hat.
                guard self.scheduleGeneration == myGeneration else { return }
                self.handlePlaybackFinished()
            }
        }
    }

    private func currentFrame() -> AVAudioFramePosition? {
        guard let lastRender = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRender)
        else { return nil }
        return seekFrame + playerTime.sampleTime
    }

    private func handlePlaybackFinished() {
        guard let file = audioFile else { return }
        // Only act if we played through to the end (not stopped by a seek/pause)
        if isPlaying {
            seekFrame = 0
            position = 0
            playerNode.stop()
            isPlaying = false
            stopPositionTimer()
            scheduleFromSeekFrame()
            _ = file
        }
    }

    // MARK: - Position polling

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPosition()
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tickPosition() {
        guard isPlaying, let frame = currentFrame() else { return }
        let secs = TimeInterval(frame) / sampleRate
        position = min(max(0, secs), duration)
    }
}
