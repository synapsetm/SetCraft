import Foundation

/// Erwarteter BPM-Bereich für die Oktav-Korrektur. aubio liefert manchmal
/// halbe oder doppelte Werte (klassisches DnB-Beispiel: 174 → 87). Wir
/// projizieren das Ergebnis in den hier definierten Bereich, indem wir
/// gegebenenfalls verdoppeln oder halbieren.
public enum BPMRangePreset: String, CaseIterable, Sendable, Identifiable, Hashable {
    case universal
    case dnb
    case house
    case hipHop
    case disco

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .universal: return "Universal (75–185)"
        case .dnb:       return "DnB (140–185)"
        case .house:     return "House (115–135)"
        case .hipHop:    return "HipHop (75–110)"
        case .disco:     return "Disco (105–130)"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .universal: return 75...185
        case .dnb:       return 140...185
        case .house:     return 115...135
        case .hipHop:    return 75...110
        case .disco:     return 105...130
        }
    }

    /// Bringt `bpm` durch Verdoppeln/Halbieren in den Erwartungs-Bereich,
    /// wenn das ohne weiteres Faktor möglich ist. Liegt der Wert auch nach
    /// einer Korrektur nicht im Bereich, gibt der Originalwert zurück
    /// (die UI kann ihn dann immer noch zeigen, und der Nutzer korrigiert).
    public func corrected(_ bpm: Double) -> Double {
        guard bpm > 0 else { return bpm }
        let r = range
        var v = bpm
        var safety = 0
        while v < r.lowerBound && safety < 4 {
            v *= 2
            safety += 1
        }
        while v > r.upperBound && safety < 8 {
            v /= 2
            safety += 1
        }
        return r.contains(v) ? v : bpm
    }
}
