import Accelerate
import Foundation
import OSLog

/// Berechnet die RGB-Waveform eines Tracks per FFT in 1024-Sample-Fenstern
/// (Hann-Window, 50 % Overlap). Die Energie pro Fenster wird in drei
/// frequenzgebundene Bänder (Bass < 200 Hz, Mitte 200 Hz–2 kHz, Höhen > 2 kHz)
/// summiert und über alle Bänder track-weit auf 0…1 normiert.
///
/// Die Analyse läuft **blockweise mit dem Decoder mit**: Bins entstehen,
/// während dekodiert wird, und `analyze(url:onPartial:)` reicht unterwegs
/// Zwischenstände heraus. Die Welle wächst damit von links nach rechts,
/// statt bis zum Schluss leer zu bleiben — und nichts von der Datei muss
/// dafür im Speicher liegen.
public enum WaveformAnalyzer {

    private static let log = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "Waveform")

    private static let windowSize: Int = 1024
    private static let hopSize: Int = 512
    private static let log2n: vDSP_Length = 10  // log2(1024)

    // Cutoffs gem. SPEC §2
    private static let bassUpperHz: Double = 200
    private static let midUpperHz: Double = 2_000

    /// Wie oft höchstens ein Zwischenstand herausgereicht wird. 200 ms fühlen
    /// sich flüssig an und kosten pro Update nur eine Array-Kopie der bisher
    /// berechneten Bins.
    private static let partialInterval: Double = 0.2

    /// Vollständige Analyse ohne Zwischenstände.
    public static func analyze(url: URL) throws -> WaveformData {
        try analyze(url: url, onPartial: { _ in })
    }

    /// Analyse mit Zwischenständen. `onPartial` wird während des Dekodierens
    /// gedrosselt mit dem bisherigen Stand gerufen (gegen das bis dahin
    /// gesehene Maximum normiert); der Rückgabewert ist das fertige, exakt
    /// normierte Ergebnis.
    ///
    /// `onPartial` läuft auf dem aufrufenden Thread — also dem, auf dem auch
    /// dekodiert wird. Wer davon die UI füttert, muss selbst hopsen.
    public static func analyze(
        url: URL,
        onPartial: (WaveformData) -> Void
    ) throws -> WaveformData {
        try analyze(url: url, partialInterval: partialInterval, onPartial: onPartial)
    }

    /// Wie oben, aber mit einstellbarer Drosselung — Tests geben 0 an, damit
    /// jeder Block einen Zwischenstand auslöst.
    static func analyze(
        url: URL,
        partialInterval: Double,
        onPartial: (WaveformData) -> Void
    ) throws -> WaveformData {
        var builder: BinBuilder?
        var lastEmit = ContinuousClock.now

        try PCMLoader.stream(
            url: url,
            onStart: { format in
                // Auch der Neustart des Decoders (Fallback-Pfad) landet hier:
                // frischer Builder, alles bisher Gerechnete ist ungültig.
                builder = BinBuilder(
                    sampleRate: format.sampleRate,
                    estimatedFrameCount: format.estimatedFrameCount,
                    windowSize: windowSize,
                    hopSize: hopSize,
                    log2n: log2n,
                    bassUpperHz: bassUpperHz,
                    midUpperHz: midUpperHz
                )
                lastEmit = ContinuousClock.now
            },
            onBlock: { block in
                guard let builder else { return }
                builder.append(block)
                let now = ContinuousClock.now
                if (now - lastEmit) >= .seconds(partialInterval), builder.binCount > 0 {
                    lastEmit = now
                    onPartial(builder.snapshot())
                }
            }
        )

        guard let builder, builder.binCount > 0 else {
            // Datei war kürzer als ein Fenster — kein Fehler, nur nichts zu
            // zeichnen.
            return WaveformData(bins: [], sampleRate: 0, secondsPerBin: 0)
        }
        let result = builder.finish()
        log.info("Waveform: \(result.bins.count) bins, \(result.secondsPerBin)s pro bin")
        return result
    }

    /// Analyse über bereits dekodierte Samples. Bleibt für Aufrufer, die den
    /// PCM ohnehin schon in der Hand halten.
    public static func analyze(pcm: PCMLoader.PCM) -> WaveformData {
        let frameCount = pcm.samples.count / MemoryLayout<Float>.size
        guard frameCount >= windowSize else {
            return WaveformData(bins: [], sampleRate: pcm.sampleRate, secondsPerBin: 0)
        }
        let builder = BinBuilder(
            sampleRate: pcm.sampleRate,
            estimatedFrameCount: frameCount,
            windowSize: windowSize,
            hopSize: hopSize,
            log2n: log2n,
            bassUpperHz: bassUpperHz,
            midUpperHz: midUpperHz
        )
        guard let builder else {
            return WaveformData(bins: [], sampleRate: pcm.sampleRate, secondsPerBin: 0)
        }
        // In Blöcken durchschieben statt am Stück: derselbe Pfad wie beim
        // Streaming, und der Überhang-Puffer bleibt klein.
        let blockSize = 16_384
        pcm.samples.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: Float.self)
            var offset = 0
            while offset < frameCount {
                let end = min(frameCount, offset + blockSize)
                builder.append(UnsafeBufferPointer(rebasing: all[offset..<end]))
                offset = end
            }
        }
        return builder.finish()
    }
}

/// Zustandsbehafteter Kern der Analyse: nimmt Sample-Blöcke entgegen und
/// erzeugt daraus Bins. Festgehalten wird nur der Überhang zwischen zwei
/// Blöcken (< ein Fenster) — nie die Datei.
private final class BinBuilder {

    private let sampleRate: Double
    private let windowSize: Int
    private let hopSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let bassMaxBin: Int
    private let midMaxBin: Int
    private let expectedBinCount: Int

    private var hann: [Float]
    /// Noch nicht zu einem vollen Fenster gewordene Samples.
    private var carry: [Float] = []
    private var windowed: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var magnitudes: [Float]

    /// Rohe, noch unnormierte Bins.
    private var bins: [WaveformBin] = []
    private var maxRms: Float = 1e-9
    private var maxBand: Float = 1e-9

    var binCount: Int { bins.count }

    init?(
        sampleRate: Double,
        estimatedFrameCount: Int,
        windowSize: Int,
        hopSize: Int,
        log2n: vDSP_Length,
        bassUpperHz: Double,
        midUpperHz: Double
    ) {
        guard sampleRate > 0, let setup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else {
            return nil
        }
        self.sampleRate = sampleRate
        self.windowSize = windowSize
        self.hopSize = hopSize
        self.log2n = log2n
        self.fftSetup = setup

        let binSize = sampleRate / Double(windowSize)
        self.bassMaxBin = min(windowSize / 2 - 1, Int((bassUpperHz / binSize).rounded(.down)))
        self.midMaxBin  = min(windowSize / 2 - 1, Int((midUpperHz  / binSize).rounded(.down)))
        self.expectedBinCount = estimatedFrameCount >= windowSize
            ? (estimatedFrameCount - windowSize) / hopSize + 1
            : 0

        self.hann = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hann, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
        self.windowed   = [Float](repeating: 0, count: windowSize)
        self.realIn     = [Float](repeating: 0, count: windowSize / 2)
        self.imagIn     = [Float](repeating: 0, count: windowSize / 2)
        self.magnitudes = [Float](repeating: 0, count: windowSize / 2)

        carry.reserveCapacity(windowSize + 16_384)
        if expectedBinCount > 0 { bins.reserveCapacity(expectedBinCount) }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func append(_ block: UnsafeBufferPointer<Float>) {
        carry.append(contentsOf: block)

        var offset = 0
        carry.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            while offset + windowSize <= ptr.count {
                makeBin(from: base + offset)
                offset += hopSize
            }
        }
        // Verbrauchte Samples wegwerfen; der Rest ist der Überhang fürs
        // nächste Fenster (50 % Overlap heisst: hopSize weniger als ein
        // volles Fenster bleibt stehen).
        if offset > 0 { carry.removeFirst(offset) }
    }

    /// Zwischenstand, normiert gegen das bisher gesehene Maximum. Läuft
    /// später eine lautere Stelle ein, justiert sich die Höhe beim nächsten
    /// Update nach — sichtbar ist das kaum, weil das Maximum meist früh steht.
    func snapshot() -> WaveformData {
        WaveformData(
            bins: normalized(),
            sampleRate: sampleRate,
            secondsPerBin: Double(hopSize) / sampleRate,
            expectedBinCount: max(expectedBinCount, bins.count)
        )
    }

    /// Endergebnis mit exakter Normierung über den ganzen Track.
    func finish() -> WaveformData {
        WaveformData(
            bins: normalized(),
            sampleRate: sampleRate,
            secondsPerBin: Double(hopSize) / sampleRate,
            expectedBinCount: bins.count
        )
    }

    // MARK: - Intern

    /// Ein Fenster → ein Bin. Roh, die Normierung passiert erst beim Ausliefern.
    private func makeBin(from window: UnsafePointer<Float>) {
        vDSP_vmul(window, 1, hann, 1, &windowed, 1, vDSP_Length(windowSize))

        // Time-domain RMS für die Säulenhöhe.
        var meanSquare: Float = 0
        vDSP_measqv(windowed, 1, &meanSquare, vDSP_Length(windowSize))
        let rms = sqrt(meanSquare)

        // Reelles Signal → Split-Complex packen.
        windowed.withUnsafeBufferPointer { winPtr in
            realIn.withUnsafeMutableBufferPointer { rPtr in
                imagIn.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!,
                                                imagp: iPtr.baseAddress!)
                    winPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: windowSize / 2
                    ) { cmplxPtr in
                        vDSP_ctoz(cmplxPtr, 2, &split, 1, vDSP_Length(windowSize / 2))
                    }
                    // Forward FFT in-place.
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, Int32(FFT_FORWARD))
                    // Magnituden.
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(windowSize / 2))
                }
            }
        }

        // Band-Summen. DC-Bin (Index 0) bewusst überspringen. Wichtig:
        // die Bänder haben SEHR unterschiedlich viele Bins (Bass ~4,
        // Mitten ~42, Höhen ~465). Wir teilen deshalb durch die Bin-
        // Anzahl, damit die Energien pro Band vergleichbar sind.
        // Ohne das würden die Höhen visuell immer dominieren.
        var bass: Float = 0
        var mid: Float  = 0
        var high: Float = 0
        let bassCount = bassMaxBin
        let midCount  = max(0, midMaxBin - bassMaxBin)
        let highStart = midMaxBin + 1
        let highCount = max(0, windowSize / 2 - highStart)
        magnitudes.withUnsafeBufferPointer { magPtr in
            let base = magPtr.baseAddress!
            if bassCount >= 1 {
                vDSP_sve(base + 1, 1, &bass, vDSP_Length(bassCount))
            }
            if midCount > 0 {
                vDSP_sve(base + bassMaxBin + 1, 1, &mid, vDSP_Length(midCount))
            }
            if highCount > 0 {
                vDSP_sve(base + highStart, 1, &high, vDSP_Length(highCount))
            }
        }
        let bassAvg = bassCount > 0 ? bass / Float(bassCount) : 0
        let midAvg  = midCount  > 0 ? mid  / Float(midCount)  : 0
        let highAvg = highCount > 0 ? high / Float(highCount) : 0

        if rms     > maxRms  { maxRms  = rms }
        if bassAvg > maxBand { maxBand = bassAvg }
        if midAvg  > maxBand { maxBand = midAvg }
        if highAvg > maxBand { maxBand = highAvg }

        bins.append(WaveformBin(rms: rms, bass: bassAvg, mid: midAvg, high: highAvg))
    }

    /// rms wird über alle Bins normiert (Säulenhöhe), die drei Bänder werden
    /// gegen denselben globalen Max-Wert normiert. So zeigt eine bass-lastige
    /// Stelle Rot mit nahezu null Grün/Blau — und nicht Weiß, was passieren
    /// würde, wenn jedes Band einzeln auf 1.0 normiert wäre.
    private func normalized() -> [WaveformBin] {
        let invRms = 1 / maxRms
        let invBand = 1 / maxBand
        return bins.map {
            WaveformBin(
                rms:  $0.rms  * invRms,
                bass: $0.bass * invBand,
                mid:  $0.mid  * invBand,
                high: $0.high * invBand
            )
        }
    }
}
