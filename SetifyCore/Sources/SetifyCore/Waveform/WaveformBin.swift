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

/// Vollständige Waveform-Daten eines Tracks plus die Sample-Rate, mit der
/// sie berechnet wurden (für Cache-Invalidierung bei Format-Änderungen).
public struct WaveformData: Sendable {
    public let bins: [WaveformBin]
    public let sampleRate: Double
    public let secondsPerBin: Double

    public init(bins: [WaveformBin], sampleRate: Double, secondsPerBin: Double) {
        self.bins = bins
        self.sampleRate = sampleRate
        self.secondsPerBin = secondsPerBin
    }
}
