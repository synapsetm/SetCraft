import AVFoundation
import Foundation
import Observation

/// Eigene Queues fürs Materialisieren von Dateien. Bewusst **nicht** der
/// Cooperative Pool von Swift Concurrency: das Öffnen einer FileProvider-
/// Datei blockiert den Thread, bis der Provider sie geliefert hat — über
/// Mobilfunk/VPN sekundenlang. Auf dem Cooperative Pool würde das dessen
/// eng begrenzte Threads belegen.
///
/// Beide **seriell**, und getrennt nach Dringlichkeit. Das deckelt die Zahl
/// gleichzeitiger Downloads auf zwei: einen für den Track, den der Nutzer
/// hören will, einen spekulativen voraus. Eine `.concurrent`-Queue hatte hier
/// den gegenteiligen Effekt — zwanzig schnelle Skips starteten zwanzig
/// parallele Voll-Downloads, die sich gegenseitig (und den gerade laufenden
/// Track) die Bandbreite wegnahmen.
private let audioLoadQueue = DispatchQueue(
    label: "ch.buehler.beat.SetCraft.audio-load",
    qos: .userInitiated
)
private let audioLookaheadQueue = DispatchQueue(
    label: "ch.buehler.beat.SetCraft.audio-lookahead",
    qos: .utility
)

/// Abbruch-Signal über die Isolationsgrenze hinweg. Ein laufender
/// `AVAudioFile(forReading:)` lässt sich nicht unterbrechen — was dieses Flag
/// rettet, ist die **Warteschlange**: wer abgehängt wurde, bevor er dran war,
/// zieht ohne einen einzigen Byte Transfer ab.
private final class PrefetchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

@MainActor
@Observable
public final class AVAudioEnginePlayer: AudioEngine {

    // MARK: - Public observable state

    public private(set) var isPlaying: Bool = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var loadedURL: URL?

    /// Wird gefeuert, wenn ein Track natürlich zu Ende gespielt hat
    /// (nicht bei pause/seek/load). Der iOS-PlayerStore hängt sich
    /// hier ein, um automatisch zum nächsten Track in der Liste zu
    /// springen — auf Mac bleibt der Hook ungesetzt, Verhalten dort
    /// unverändert.
    public var onPlaybackEnded: (() -> Void)?

    /// Frischer Position-Read mit Render-Drift-Korrektur. `currentFrame()`
    /// liefert die Sample-Position **bei `playerNode.lastRenderTime`** — also
    /// die Vergangenheit (bis zu eine Render-Buffer-Länge ~10 ms her). Bei
    /// aktiver Wiedergabe ist seit lastRenderTime real-time-Zeit verstrichen,
    /// in der weitere Samples wiedergegeben wurden. Ohne diese Korrektur
    /// hinkt der Playhead konsistent hinter dem hörbaren Audio her.
    ///
    /// Korrektur: (host-now − lastRenderTime) × engine.rate Sekunden auf
    /// die Rendered-Position addieren. Wird vom Waveform-Renderer in einer
    /// `TimelineView(.periodic)` 60 × pro Sekunde aufgerufen.
    public var livePosition: TimeInterval {
        guard isPlaying,
              let lastRender = playerNode.lastRenderTime,
              let playerTimeAtRender = playerNode.playerTime(forNodeTime: lastRender)
        else { return position }

        let renderedSamples = seekFrame + playerTimeAtRender.sampleTime
        let renderedSeconds = TimeInterval(renderedSamples) / sampleRate

        // Drift seit dem letzten Render-Callback aufholen.
        let nowHostTime = mach_absolute_time()
        let elapsedSeconds: TimeInterval
        if nowHostTime >= lastRender.hostTime {
            let hostDelta = nowHostTime - lastRender.hostTime
            elapsedSeconds = AVAudioTime.seconds(forHostTime: hostDelta)
        } else {
            elapsedSeconds = 0
        }

        // Plus PlayerNode-Output-Presentation-Latency: das ist die Zeit vom
        // gerade gerenderten Sample des PlayerNode bis zur hörbaren Ausgabe
        // an der Hardware. Sie summiert TimePitch-Verarbeitung (~93 ms),
        // Mixer und Hardware-Buffer (~203 ms). `engine.outputNode.outputPresentationLatency`
        // würde nur den Hardware-Anteil zählen und die TimePitch-Latenz
        // unter den Tisch fallen lassen — die Anzeige hinkte dann um genau
        // diese Differenz hinter dem hörbaren Audio her.
        let presentationLatency = playerNode.outputPresentationLatency

        let projected = renderedSeconds + (elapsedSeconds + presentationLatency) * rate
        return min(max(0, projected), duration)
    }

    // Stored properties, damit @Observable die Änderungen mitbekommt und
    // SwiftUI-Views (Chips, Slider, Anzeige) sich erneuern. didSet syncht
    // den geklemmten Wert auf den nicht-observable AVAudioUnitTimePitch-Knoten.
    public var rate: Double = 1.0 {
        didSet {
            let clamped = max(0.5, min(2.0, rate))
            timePitch.rate = Float(clamped)
            if rate != clamped { rate = clamped }
            syncPitch()
        }
    }

    public var pitchCents: Double = 0 {
        didSet {
            let clamped = max(-2400, min(2400, pitchCents))
            if pitchCents != clamped { pitchCents = clamped }
            syncPitch()
        }
    }

    /// Schreibt den effektiven Pitch auf den Knoten: der vom Master-Key
    /// gesetzte Offset plus die Verschiebung, die sich aus der Rate ergibt.
    ///
    /// `AVAudioUnitTimePitch` würde die Tonhöhe beim Tempowechsel von sich aus
    /// konstant halten. Das kompensieren wir hier bewusst — SetCraft spielt
    /// ohne Key-Lock, damit sich die Tonart wie beim Plattenspieler mit dem
    /// Tempo verschiebt und die Anzeige in der Bibliothek dem Gehörten
    /// entspricht (siehe `SPEC.md` §5b).
    private func syncPitch() {
        let varispeed = PitchMath.cents(forRate: rate)
        timePitch.pitch = Float(max(-2400, min(2400, pitchCents + varispeed)))
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

    /// Holt die Datei auf das Gerät, ohne den MainActor zu blockieren.
    ///
    /// `AVAudioFile(forReading:)` kehrt bei einer Datei, die über den
    /// FileProvider kommt (iCloud Drive, aber genauso ein SMB/NAS-Share aus
    /// der Files-App), erst zurück, wenn der Provider sie vollständig lokal
    /// materialisiert hat. Im Heim-WLAN fällt das nicht auf; über Mobilfunk
    /// oder VPN sind das mehrere Sekunden — auf dem MainActor also ein
    /// eingefrorenes UI.
    ///
    /// Genau dieser blockierende Open passiert hier auf einer eigenen Queue
    /// und wird sofort wieder verworfen. Das anschliessende `load(url:)` auf
    /// dem MainActor trifft dann auf die lokale Kopie und kehrt sofort zurück.
    ///
    /// Bei einer lokalen Datei kostet der Aufruf nur den Open — kein
    /// Sonderfall nötig.
    public nonisolated static func prefetch(url: URL) async {
        await materialize(url: url, on: audioLoadQueue)
    }

    /// Wie `prefetch(url:)`, aber spekulativ: für den Track, der als nächstes
    /// **wahrscheinlich** gebraucht wird. Eigene Queue mit niedrigerer
    /// Priorität, damit die Vorausschau dem Track, den der Nutzer gerade
    /// angetippt hat, nie im Weg steht.
    public nonisolated static func prefetchAhead(url: URL) async {
        await materialize(url: url, on: audioLookaheadQueue)
    }

    private nonisolated static func materialize(url: URL, on queue: DispatchQueue) async {
        // Wer schon vor dem Einreihen abgebrochen wurde, fasst gar nichts an.
        if Task.isCancelled { return }

        let cancellation = PrefetchCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    // Die Queue ist seriell — hier steht man ggf. hinter einem
                    // Vorgänger. Erst jetzt prüfen, ob das Ergebnis überhaupt
                    // noch jemanden interessiert: bei schnellem Durchskippen
                    // fallen so alle Zwischenstationen ohne IO weg.
                    guard !cancellation.isCancelled else {
                        continuation.resume()
                        return
                    }

                    var coordinatorError: NSError?
                    // Der `NSFileCoordinator` ist derselbe Weg, den
                    // `FolderScanner.collect` beim Verzeichnis-Lesen geht: er
                    // gibt dem Provider die Gelegenheit, die Datei
                    // bereitzustellen, statt uns einen Platzhalter
                    // unterzuschieben.
                    NSFileCoordinator().coordinate(
                        readingItemAt: url,
                        options: [],
                        error: &coordinatorError
                    ) { coordinatedURL in
                        // Öffnen genügt — dabei materialisiert der Provider.
                        // Das AVAudioFile verlässt diese Closure nie, überquert
                        // also keine Isolationsgrenze (es ist nicht Sendable);
                        // der eigentliche Load baut es ohnehin neu auf.
                        _ = try? AVAudioFile(forReading: coordinatedURL)
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

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

        // Die klassische `connect(_:to:format:)` meldet ein Format, mit dem sie
        // nichts anfangen kann, als Objective-C-Exception — und die kann Swift
        // nicht fangen, der Prozess stirbt. Bei einer Bibliothek aus fremden
        // Dateien ist das eine reale Absturzquelle. Ab iOS/macOS 27 gibt es
        // dieselbe Verbindung mit `error:`; dann landet ein unverdauliches
        // Format im `catch` des Aufrufers statt im Crash-Log.
        if #available(iOS 27.0, macOS 27.0, *) {
            try engine.connectNode(playerNode, to: timePitch, format: file.processingFormat)
            try engine.connectNode(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        } else {
            engine.connect(playerNode, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        }

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
            onPlaybackEnded?()
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
