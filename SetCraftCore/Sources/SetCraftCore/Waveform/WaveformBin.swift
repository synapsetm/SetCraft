import Foundation

/// Ein Zeitfenster der Waveform-Analyse. `rms` bestimmt die Säulenhöhe, die
/// drei Band-Energien (bass/mid/high) die RGB-Färbung. Alle Werte sind
/// bereits über den gesamten Track normiert (0…1).
public struct WaveformBin: Sendable, Hashable {
    public var rms: Float
    public var bass: Float
    public var mid: Float
    public var high: Float

    public init(rms: Float, bass: Float, mid: Float, high: Float) {
        self.rms = rms
        self.bass = bass
        self.mid = mid
        self.high = high
    }
}

/// Waveform-Daten eines Tracks plus die Sample-Rate, mit der sie berechnet
/// wurden (für Cache-Invalidierung bei Format-Änderungen).
///
/// Kann ein **Zwischenstand** sein: die Analyse läuft blockweise und liefert
/// unterwegs Teilergebnisse, damit die Welle wächst, statt minutenlang leer
/// zu bleiben. `expectedBinCount` sagt, wie breit die fertige Welle wird —
/// die Views zeichnen darum nur den bereits berechneten linken Teil und
/// lassen den Rest leer, statt das Teilstück über die volle Breite zu
/// strecken.
public struct WaveformData: Sendable {
    public let bins: [WaveformBin]
    public let sampleRate: Double
    public let secondsPerBin: Double
    /// Geschätzte Bin-Anzahl des fertigen Tracks (aus der Dateilänge). Bei
    /// abgeschlossener Analyse gleich `bins.count`.
    public let expectedBinCount: Int

    /// `false`, solange noch Bins nachkommen.
    public var isComplete: Bool { bins.count >= expectedBinCount }

    /// Zeitachse, über die sich die fertige Welle erstreckt — während der
    /// Analyse die Schätzung, danach der exakte Wert. Bezugsgrösse für den
    /// Playhead, damit er nicht springt, während die Welle noch wächst.
    public var totalSeconds: Double {
        Double(max(bins.count, expectedBinCount)) * secondsPerBin
    }

    /// Anteil der bereits berechneten Welle (0…1).
    public var completion: Double {
        guard expectedBinCount > 0 else { return bins.isEmpty ? 0 : 1 }
        return min(1, Double(bins.count) / Double(expectedBinCount))
    }

    public init(
        bins: [WaveformBin],
        sampleRate: Double,
        secondsPerBin: Double,
        expectedBinCount: Int? = nil
    ) {
        self.bins = bins
        self.sampleRate = sampleRate
        self.secondsPerBin = secondsPerBin
        self.expectedBinCount = expectedBinCount ?? bins.count
    }
}
