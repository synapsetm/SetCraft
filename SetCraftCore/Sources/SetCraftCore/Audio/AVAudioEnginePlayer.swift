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

    /// Die Position, die der Nutzer in diesem Moment **hört** — nicht die,
    /// die der PlayerNode schon in den Graphen geschoben hat.
    ///
    /// `playerTime(forNodeTime: lastRenderTime).sampleTime` liefert die
    /// Sample-Position `S` des letzten Render-Zyklus. Zwei Dinge liegen
    /// zwischen `S` und dem Lautsprecher, und beide zeigen in die **Zukunft**:
    ///
    /// 1. `lastRenderTime.hostTime` ist nicht der Moment des Renderns, sondern
    ///    die anvisierte Ausgabezeit des gerade gerenderten Buffers. Gemessen
    ///    auf macOS liegt sie konstant **14–22 ms in der Zukunft**. Die Differenz
    ///    muss darum **signiert** bleiben — ein Clamp auf 0 macht die Korrektur
    ///    zu totem Code, weil `now >= hostTime` während der Wiedergabe nie gilt.
    /// 2. `outputLatency` ist die Strecke von diesem Node bis zur Emission:
    ///    TimePitch-Verarbeitung (gemessen 93 ms), Mixer und Hardware-Buffer,
    ///    bei Bluetooth zusätzlich die Funkstrecke (AirPods 150–200 ms).
    ///
    /// Also: hörbar ist `S − (hostTime − now) − outputLatency`, in Audio-Sekunden
    /// über `rate` skaliert. Beide Terme werden **abgezogen**; sie zu addieren
    /// schob die Anzeige um deren doppelten Betrag nach vorn — genau das war
    /// der „Waveform läuft dem Ton voraus"-Befund.
    public var livePosition: TimeInterval {
        audiblePosition() ?? position
    }

    /// Gemeinsame Rechnung für `livePosition`, den 30-Hz-Timer und `pause()`.
    /// Gibt `nil` zurück, solange nichts läuft oder noch kein Render-Zyklus
    /// stattgefunden hat.
    private func audiblePosition() -> TimeInterval? {
        guard isPlaying,
              let lastRender = playerNode.lastRenderTime,
              let playerTimeAtRender = playerNode.playerTime(forNodeTime: lastRender)
        else { return nil }

        let renderedSamples = seekFrame + playerTimeAtRender.sampleTime
        let renderedSeconds = TimeInterval(renderedSamples) / sampleRate

        // Signierter Abstand zur anvisierten Ausgabezeit: positiv, wenn sie
        // noch aussteht (Normalfall), negativ, wenn sie verstrichen ist.
        let nowHostTime = mach_absolute_time()
        let untilPresentation: TimeInterval
        if lastRender.hostTime >= nowHostTime {
            untilPresentation = AVAudioTime.seconds(forHostTime: lastRender.hostTime - nowHostTime)
        } else {
            untilPresentation = -AVAudioTime.seconds(forHostTime: nowHostTime - lastRender.hostTime)
        }

        let projected = renderedSeconds - (untilPresentation + outputLatency) * rate
        return min(max(0, projected), duration)
    }

    /// Zeit vom PlayerNode-Output bis zur hörbaren Emission.
    ///
    /// `playerNode.outputPresentationLatency` ist die semantisch richtige Größe
    /// und deckt auf dem Mac alles ab (93 ms TimePitch + 1 ms Hardware; das
    /// `outputNode`-Pendant allein kennt die TimePitch-Latenz nicht).
    ///
    /// Auf iOS ist nicht verlässlich, ob der Node die Route kennt — über
    /// Bluetooth liegen dort 150–200 ms Funkstrecke, die `AVAudioSession`
    /// in `outputLatency` ausweist. Darum das **Maximum** beider Schätzungen
    /// derselben Strecke: das greift die Quelle ab, die von der Route weiß,
    /// ohne sie doppelt zu zählen.
    private var outputLatency: TimeInterval {
        let nodeLatency = playerNode.outputPresentationLatency
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let sessionLatency = session.outputLatency + session.ioBufferDuration + timePitch.latency
        return max(nodeLatency, sessionLatency)
        #else
        return nodeLatency
        #endif
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
        // Bewusst die HÖRBARE Position, nicht die gerenderte: `playerNode.stop()`
        // verwirft den gepufferten Vorlauf, der nie zu hören war. Vom gerenderten
        // Frame aus fortzusetzen überspränge genau diesen Vorlauf.
        if let secs = audiblePosition() {
            seekFrame = AVAudioFramePosition(secs * sampleRate)
            position = secs
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

    /// Speist die @Observable-`position` mit derselben hörbaren Position wie
    /// `livePosition`. Damit sind Zeitanzeige, Mini-Player, Now-Playing und die
    /// iOS-Waveform latenz-korrigiert, ohne dass jeder Leser das wissen muss;
    /// `livePosition` bleibt der Weg für alles, was feiner als 30 Hz tickt.
    private func tickPosition() {
        guard isPlaying, let secs = audiblePosition() else { return }
        position = secs
    }
}
