import Accelerate
import Foundation
import OSLog

/// Berechnet die RGB-Waveform eines Tracks per FFT in 1024-Sample-Fenstern
/// (Hann-Window, 50 % Overlap). Die Energie pro Fenster wird in drei
/// frequenzgebundene Bänder (Bass < 200 Hz, Mitte 200 Hz–2 kHz, Höhen > 2 kHz)
/// summiert und am Schluss über alle Bänder track-weit auf 0…1 normiert.
public enum WaveformAnalyzer {

    private static let log = Logger(subsystem: "ch.beat.buehler.Setify", category: "Waveform")

    private static let windowSize: Int = 1024
    private static let hopSize: Int = 512
    private static let log2n: vDSP_Length = 10  // log2(1024)

    // Cutoffs gem. SPEC §2
    private static let bassUpperHz: Double = 200
    private static let midUpperHz: Double = 2_000

    public static func analyze(url: URL) throws -> WaveformData {
        let pcm = try PCMLoader.load(url: url)
        return analyze(pcm: pcm)
    }

    public static func analyze(pcm: PCMLoader.PCM) -> WaveformData {
        let samplesAsFloats: [Float] = pcm.samples.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
        guard samplesAsFloats.count >= windowSize else {
            return WaveformData(bins: [], sampleRate: pcm.sampleRate, secondsPerBin: 0)
        }

        let binSize = pcm.sampleRate / Double(windowSize)
        let bassMaxBin = min(windowSize / 2 - 1, Int((bassUpperHz / binSize).rounded(.down)))
        let midMaxBin  = min(windowSize / 2 - 1, Int((midUpperHz  / binSize).rounded(.down)))

        log.debug("Waveform: \(samplesAsFloats.count) samples, bass≤bin\(bassMaxBin), mid≤bin\(midMaxBin)")

        // Hann-Fenster vorberechnen.
        var hann = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hann, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        // FFT-Setup einmalig.
        guard let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else {
            return WaveformData(bins: [], sampleRate: pcm.sampleRate, secondsPerBin: 0)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let frameCount = (samplesAsFloats.count - windowSize) / hopSize + 1
        var bins: [WaveformBin] = []
        bins.reserveCapacity(frameCount)

        var windowed = [Float](repeating: 0, count: windowSize)
        var realIn   = [Float](repeating: 0, count: windowSize / 2)
        var imagIn   = [Float](repeating: 0, count: windowSize / 2)
        var magnitudes = [Float](repeating: 0, count: windowSize / 2)

        samplesAsFloats.withUnsafeBufferPointer { sampPtr in
            for frame in 0..<frameCount {
                let offset = frame * hopSize
                // Fensterung
                vDSP_vmul(sampPtr.baseAddress! + offset, 1,
                          hann, 1,
                          &windowed, 1,
                          vDSP_Length(windowSize))

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

                // Band-Summen. DC-Bin (Index 0) bewusst überspringen.
                var bass: Float = 0
                var mid: Float  = 0
                var high: Float = 0
                let midCount  = max(0, midMaxBin - bassMaxBin)
                let highStart = midMaxBin + 1
                let highCount = max(0, windowSize / 2 - highStart)
                magnitudes.withUnsafeBufferPointer { magPtr in
                    let base = magPtr.baseAddress!
                    if bassMaxBin >= 1 {
                        vDSP_sve(base + 1, 1, &bass, vDSP_Length(bassMaxBin))
                    }
                    if midCount > 0 {
                        vDSP_sve(base + bassMaxBin + 1, 1, &mid, vDSP_Length(midCount))
                    }
                    if highCount > 0 {
                        vDSP_sve(base + highStart, 1, &high, vDSP_Length(highCount))
                    }
                }

                bins.append(WaveformBin(rms: rms, bass: bass, mid: mid, high: high))
            }
        }

        // Track-weite Normalisierung pro Kanal, damit auch leise Stellen Farbe
        // zeigen und die Säulenhöhe den vollen Bereich nutzt.
        normalize(&bins)

        let secondsPerBin = Double(hopSize) / pcm.sampleRate
        log.info("Waveform: \(bins.count) bins, \(secondsPerBin)s pro bin")
        return WaveformData(bins: bins, sampleRate: pcm.sampleRate, secondsPerBin: secondsPerBin)
    }

    /// rms wird über alle Bins normiert (Säulenhöhe), die drei Bänder werden
    /// gegen denselben globalen Max-Wert normiert. So zeigt eine bass-lastige
    /// Stelle Rot mit nahezu null Grün/Blau — und nicht Weiß, was passieren
    /// würde, wenn jedes Band einzeln auf 1.0 normiert wäre.
    private static func normalize(_ bins: inout [WaveformBin]) {
        var maxRms: Float = 1e-9
        var maxBand: Float = 1e-9
        for b in bins {
            if b.rms  > maxRms  { maxRms  = b.rms }
            if b.bass > maxBand { maxBand = b.bass }
            if b.mid  > maxBand { maxBand = b.mid }
            if b.high > maxBand { maxBand = b.high }
        }
        for i in 0..<bins.count {
            bins[i].rms  = bins[i].rms  / maxRms
            bins[i].bass = bins[i].bass / maxBand
            bins[i].mid  = bins[i].mid  / maxBand
            bins[i].high = bins[i].high / maxBand
        }
    }
}
