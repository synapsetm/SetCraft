import AVFoundation
import Foundation
import Network
import OSLog
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

/// Sagt, ob das Gerät ueberhaupt einen Netzpfad hat.
///
/// Der Unterschied, auf den es ankommt: eine **langsame** Quelle (NAS über
/// Mobilfunk) darf beliebig lange brauchen — genau dafür ist der Prefetch da.
/// Eine **unerreichbare** Quelle (Flugmodus) soll sofort aufgeben, statt den
/// Nutzer minutenlang auf einen Spinner schauen zu lassen, bis der
/// `NSFileCoordinator` von selbst aufgibt. Deshalb wird nicht die Dauer
/// gemessen, sondern der Netzzustand gefragt.
///
/// Ein NAS im lokalen WLAN ohne Internet zählt als erreichbar — `NWPathMonitor`
/// meldet den WLAN-Pfad als `satisfied`. Nur wenn es gar keinen Pfad gibt, ist
/// die Antwort „offline".
private final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var status: NWPath.Status?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.status = path.status }
        }
        monitor.start(queue: DispatchQueue(label: "ch.buehler.beat.SetCraft.reachability"))
    }

    /// `true` nur bei einer belastbaren Aussage. Solange der Monitor noch keinen
    /// Pfad geliefert hat, lautet die Antwort `false` — im Zweifel wird nicht
    /// abgebrochen, sondern gewartet wie bisher.
    var isDefinitelyOffline: Bool {
        lock.withLock { status != nil && status != .satisfied }
    }
}

/// Wie lange die drei Phasen gedauert haben. Vorübergehend eingebaut, um eine
/// konkrete Frage zu beantworten: warum ein Trackwechsel über Mobilfunk lange
/// dauert. `open` ist der `AVAudioFile`-Open, bei dem der FileProvider die Datei
/// herunterlädt; `probe` die Lesbarkeitsprüfung am Dateiende; `copy` die Kopie in
/// den Wiedergabe-Cache. Erwartung: `open` dominiert deutlich.
public struct MaterializeTiming: Sendable {
    public let open: TimeInterval
    /// Zeit für einen Read der ERSTEN Frames. Beantwortet die Frage, ob der
    /// FileProvider sequenziell liefert: ist der Kopf schnell da, während das
    /// Ende lange braucht, lässt sich losspielen, bevor die Datei komplett ist.
    /// Braucht schon der Kopf lange, liefert der Provider alles-oder-nichts und
    /// progressives Abspielen ist unmöglich — egal wie man es baut.
    public let head: TimeInterval
    public let probe: TimeInterval
    public let copy: TimeInterval
    /// Wie oft die belegte Grösse der Datei während des Downloads gewachsen
    /// ist. > 0 heisst: es gibt eine beobachtbare Fortschritts-Grösse, aus der
    /// sich ein echter Fortschrittsbalken bauen lässt.
    public let growthSamples: Int
    /// Belegt/gesamt am Ende, als Kontrolle der Messgrösse.
    public let fillRatio: Double?
}

/// Schreibt während des Downloads mit, ob die belegte Grösse der Datei wächst.
/// VORLÄUFIG — nur zur Beantwortung der Frage, ob ein Fortschrittsbalken
/// überhaupt möglich ist.
private final class AllocationWatcher: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var lastAllocated: Int64 = -1
    private var increases = 0
    private var ratio: Double?
    private var running = true

    init(url: URL) { self.url = url }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while lock.withLock({ running }) {
                let values = try? url.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey, .fileSizeKey
                ])
                let allocated = Int64(values?.totalFileAllocatedSize ?? 0)
                let total = Int64(values?.fileSize ?? 0)
                lock.withLock {
                    if allocated > lastAllocated {
                        if lastAllocated >= 0 { increases += 1 }
                        lastAllocated = allocated
                    }
                    if total > 0 { ratio = Double(allocated) / Double(total) }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    func stop() -> (increases: Int, ratio: Double?) {
        lock.withLock {
            running = false
            return (increases, ratio)
        }
    }
}

/// Ergebnis einer Materialisierung. `offline` ist bewusst ein eigener Fall und
/// kein Text: die UI-Schicht formuliert daraus eine lokalisierte Meldung, der
/// Core hat keinen String-Katalog.
public enum MaterializeOutcome: Sendable {
    case ok(timing: MaterializeTiming?)
    case offline
    case failed(reason: String)
}

/// Continuation, die sich nur einmal fortsetzen laesst. Gebraucht, weil zwei
/// Quellen um die Antwort rennen: die eigentliche IO und der Offline-Wecker.
private final class OneShotContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MaterializeOutcome, Never>?

    init(_ continuation: CheckedContinuation<MaterializeOutcome, Never>) {
        self.continuation = continuation
    }

    func resume(_ outcome: MaterializeOutcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}

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

private let playbackLog = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "Playback")

@MainActor
@Observable
public final class AVAudioEnginePlayer: AudioEngine {

    // MARK: - Public observable state

    public private(set) var isPlaying: Bool = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var loadedURL: URL?

    /// Wird gefeuert, wenn ein Track natürlich zu Ende gespielt hat
    /// (nicht bei pause/seek/load). Beide Plattformen hängen sich hier ein,
    /// um automatisch zum nächsten Track in der Liste zu springen: iOS im
    /// `PlayerStore`, macOS in `ContentView.onAppear`. Am Listenende bleibt
    /// die Wiedergabe stehen, statt von vorn zu beginnen.
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
        #if os(iOS)
        // Gecacht, weil `livePosition` in einer 60-Hz-TimelineView gelesen wird
        // und diese Werte sonst 60-mal pro Sekunde auf dem MainActor abgefragt
        // würden — Node-Properties und AVAudioSession-Properties, letztere mit
        // Weg zum Audio-Server. Die Latenz ändert sich nur beim Routenwechsel,
        // eine halbe Sekunde Nachlauf ist am Playhead nicht zu sehen.
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedOutputLatency, now - cached.measuredAt < 0.5 {
            return cached.value
        }
        let session = AVAudioSession.sharedInstance()
        let sessionLatency = session.outputLatency + session.ioBufferDuration + timePitch.latency
        let value = max(playerNode.outputPresentationLatency, sessionLatency)
        cachedOutputLatency = (value: value, measuredAt: now)
        return value
        #else
        return playerNode.outputPresentationLatency
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

    #if os(iOS)
    /// Zuletzt gemessene Ausgabe-Latenz samt Zeitstempel (`systemUptime`, weil
    /// monoton). Siehe `outputLatency`.
    private var cachedOutputLatency: (value: TimeInterval, measuredAt: TimeInterval)?
    #endif

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
    @discardableResult
    public nonisolated static func prefetch(url: URL) async throws -> MaterializeTiming? {
        switch await materialize(url: url, on: audioLoadQueue) {
        case .ok(let timing):
            return timing
        case .offline:
            throw AudioEngineError.sourceOffline
        case .failed(let reason):
            throw AudioEngineError.fileUnavailable(reason: reason)
        }
    }

    /// Wie `prefetch(url:)`, aber spekulativ: für den Track, der als nächstes
    /// **wahrscheinlich** gebraucht wird. Eigene Queue mit niedrigerer
    /// Priorität, damit die Vorausschau dem Track, den der Nutzer gerade
    /// angetippt hat, nie im Weg steht.
    public nonisolated static func prefetchAhead(url: URL) async {
        // Spekulativ: ein Fehlschlag ist hier kein Ereignis. Scheitert die
        // Vorausschau, merkt es der echte Load später selbst.
        _ = await materialize(url: url, on: audioLookaheadQueue)

    }

    /// Holt die Datei auf das Gerät.
    ///
    /// Beide Fehlerquellen wurden früher verschluckt — der `NSFileCoordinator`
    /// bekam eine `error`-Adresse, die niemand auslas, und der Open stand unter
    /// `try?`. Im Flugmodus lief der Load darum weiter, `AVAudioFile` öffnete
    /// den bereits gecachten Dateikopf (die Library liest beim Scan Tags, damit
    /// liegt der Anfang lokal vor), die Länge kam aus dem Header — und die
    /// Wiedergabe lief sichtbar los, ohne einen Ton. Genau der gemeldete Befund:
    /// „kein Audio, keine Fehlermeldung".
    private nonisolated static func materialize(url: URL, on queue: DispatchQueue) async -> MaterializeOutcome {
        // Wer schon vor dem Einreihen abgebrochen wurde, fasst gar nichts an.
        if Task.isCancelled { return .ok(timing: nil) }

        let cancellation = PrefetchCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MaterializeOutcome, Never>) in
                let once = OneShotContinuation(continuation)

                // Ohne Netzpfad hat der koordinierte Read keine Aussicht auf
                // Erfolg — er merkt es nur erst nach Minuten. Die kurze Gnadenfrist
                // ist für den Fall, dass die Datei längst lokal liegt: dann kehrt
                // die IO innerhalb von Millisekunden zurück und gewinnt das Rennen.
                if NetworkReachability.shared.isDefinitelyOffline {
                    DispatchQueue.global().asyncAfter(deadline: .now() + offlineGracePeriod) {
                        once.resume(.offline)
                    }
                }

                queue.async {
                    // Die Queue ist seriell — hier steht man ggf. hinter einem
                    // Vorgänger. Erst jetzt prüfen, ob das Ergebnis überhaupt
                    // noch jemanden interessiert: bei schnellem Durchskippen
                    // fallen so alle Zwischenstationen ohne IO weg.
                    guard !cancellation.isCancelled else {
                        once.resume(.ok(timing: nil))
                        return
                    }

                    // iCloud-Platzhalter: den Download anstossen, bevor der
                    // koordinierte Read darauf wartet.
                    //
                    // Diese Abfrage stand bis 2026-09-19 im `PlayerStore` — und
                    // zwar VOR dem ersten `await`, also synchron auf dem
                    // MainActor. `resourceValues` geht bei einer
                    // FileProvider-URL zum Provider; im Flugmodus mit einer
                    // unerreichbaren NAS kommt sie nicht zurück und hielt das
                    // ganze UI an, inklusive Scrollen und laufender Spinner.
                    // Hier liegt sie auf derselben Queue wie die IO, auf die
                    // sie sich bezieht.
                    if let values = try? url.resourceValues(forKeys: [
                        .isUbiquitousItemKey,
                        .ubiquitousItemDownloadingStatusKey
                    ]),
                       values.isUbiquitousItem == true,
                       values.ubiquitousItemDownloadingStatus != .current {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    }

                    // Die Begründung wird im Closure zu einem String gemacht,
                    // statt den NSError über die Isolationsgrenze zu schicken.
                    var failure: String?
                    var timing: MaterializeTiming?
                    var coordinatorError: NSError?
                    // Wo die Sekunden hingehen, wenn ein Trackwechsel ueber
                    // Mobilfunk lange dauert. Erwartung: der Loewenanteil steckt
                    // im Open, weil der FileProvider dabei die ganze Datei holt —
                    // Probe und Kopie laufen danach auf lokalem Speicher.
                    // Gemessen statt vermutet.
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    var openedAt = startedAt
                    var headAt = startedAt
                    var verifiedAt = startedAt
                    let watcher = AllocationWatcher(url: url)
                    watcher.start()
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
                        do {
                            let file = try AVAudioFile(forReading: coordinatedURL)
                            openedAt = ProcessInfo.processInfo.systemUptime
                            // Kopf VOR dem Ende lesen — die Reihenfolge ist der
                            // ganze Punkt der Messung.
                            _ = measureHeadRead(file)
                            headAt = ProcessInfo.processInfo.systemUptime
                            failure = verifyReadable(file)
                            verifiedAt = ProcessInfo.processInfo.systemUptime
                        } catch {
                            failure = describe(error as NSError)
                        }

                        // Nur wenn die Datei als vollständig lesbar gilt: eine
                        // eigene Kopie anlegen, aus der später gespielt wird.
                        // Noch innerhalb der Koordination, weil der Provider hier
                        // garantiert Zugriff gewährt — und auf dieser Queue, weil
                        // Kopieren blockiert.
                        if failure == nil, PlaybackCache.shared.shouldCache(url) {
                            PlaybackCache.shared.store(coordinatedURL)
                        }

                        let finishedAt = ProcessInfo.processInfo.systemUptime
                        let growth = watcher.stop()
                        timing = MaterializeTiming(
                            open: openedAt - startedAt,
                            head: headAt - openedAt,
                            probe: verifiedAt - headAt,
                            copy: finishedAt - verifiedAt,
                            growthSamples: growth.increases,
                            fillRatio: growth.ratio
                        )
                        let phases = "open \(round((openedAt - startedAt) * 100) / 100)s, probe \(round((verifiedAt - openedAt) * 100) / 100)s, copy \(round((finishedAt - verifiedAt) * 100) / 100)s"
                        playbackLog.info("Materialisiert \(url.lastPathComponent, privacy: .public): \(phases, privacy: .public)")
                    }
                    if let coordinatorError {
                        // Der Coordinator kommt zuerst: kann er die Datei nicht
                        // bereitstellen, lief die Closure oben gar nicht.
                        failure = describe(coordinatorError)
                    }
                    once.resume(failure.map { .failed(reason: $0) } ?? .ok(timing: timing))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Wie lange bei bekannt fehlendem Netzpfad noch auf die IO gewartet wird,
    /// bevor `offline` gemeldet wird. Lang genug, dass ein rein lokaler Open
    /// gewinnt; kurz genug, dass niemand auf einen aussichtslosen Spinner starrt.
    private nonisolated static let offlineGracePeriod: TimeInterval = 3

    /// Macht aus einem `NSError` etwas, das in einer Meldung weiterhilft.
    /// `localizedDescription` allein liefert bei Datei-Fehlern die Cocoa-Floskel
    /// „The operation couldn’t be completed." — ohne Domain, Code und den
    /// eigentlich interessanten POSIX-Errno aus `NSUnderlyingError`. Gleiche
    /// Begründung wie bei den Tag-Write-Fehlern in `TagLibTrackStore`.
    private nonisolated static func describe(_ error: NSError) -> String {
        var parts = [error.localizedDescription]
        parts.append("(\(error.domain) \(error.code)")
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts[parts.count - 1] += ", \(underlying.domain) \(underlying.code)"
            if underlying.domain == NSPOSIXErrorDomain,
               let name = String(validatingCString: strerror(Int32(underlying.code))) {
                parts[parts.count - 1] += " — \(name)"
            }
        }
        parts[parts.count - 1] += ")"
        return parts.joined(separator: " ")
    }

    /// Prüft, ob die Datei wirklich vollständig lokal liegt — und nicht nur ihr
    /// Kopf. Gelesen wird ein Puffer am **Ende**: ein Provider, der bloss den
    /// Anfang gecacht hat, muss dafür den Rest holen oder scheitern. Ohne diese
    /// Probe wandert eine halb übertragene Datei in die Engine und wird als
    /// Stille abgespielt.
    /// Liest die ERSTEN Frames und liefert die dafür gebrauchte Zeit.
    /// VORLÄUFIG — siehe `MaterializeTiming.head`.
    private nonisolated static func measureHeadRead(_ file: AVAudioFile) -> TimeInterval {
        let started = ProcessInfo.processInfo.systemUptime
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)
        else { return 0 }
        file.framePosition = 0
        try? file.read(into: buffer)
        return ProcessInfo.processInfo.systemUptime - started
    }

    private nonisolated static func verifyReadable(_ file: AVAudioFile) -> String? {
        let format = file.processingFormat
        let probeFrames: AVAudioFrameCount = 4_096
        guard file.length > 0 else {
            return "The file contains no audio data."
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: probeFrames) else {
            return nil   // Kein Urteil möglich — dann nicht im Weg stehen.
        }
        let tailStart = max(0, file.length - AVAudioFramePosition(probeFrames))
        do {
            file.framePosition = tailStart
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else {
                return "The file could not be read completely — the source may be offline."
            }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    public func load(url: URL) throws {
        stopPlayback()

        // Aus der Cache-Kopie spielen, wenn es eine gibt: damit hängt die
        // Wiedergabe nicht mehr am FileProvider und übersteht einen Netzverlust,
        // ohne stumm weiterzulaufen. `loadedURL` bleibt bewusst die QUELLE — sie
        // ist die Identität des Tracks für Library, Tag-Writes und Waveform.
        // `existingCopy` kostet nur einen `stat`, ist auf dem MainActor also
        // unbedenklich; angelegt wird die Kopie im Prefetch.
        let playbackURL = PlaybackCache.shared.existingCopy(of: url) ?? url
        let file = try AVAudioFile(forReading: playbackURL)
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
        #if os(iOS)
        // Neues Format, womöglich andere Node-Latenz — Messung nicht wiederverwenden.
        cachedOutputLatency = nil
        #endif
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
