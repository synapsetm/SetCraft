import Foundation

/// Erwarteter BPM-Bereich für die Oktav-Korrektur. aubio liefert manchmal
/// halbe oder doppelte Werte (klassisches DnB-Beispiel: 174 → 87). Wir
/// projizieren das Ergebnis in den hier definierten Bereich, indem wir
/// gegebenenfalls verdoppeln oder halbieren.
public enum BPMRangePreset: String, CaseIterable, Sendable, Identifiable, Hashable {
    case universal
    case dnb
    case psyTrance
    case house
    case hipHop
    case disco

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .universal: return "Universal (75–185)"
        case .dnb:       return "DnB (140–185)"
        case .psyTrance: return "Psy-Trance (135–165)"
        case .house:     return "House (115–135)"
        case .hipHop:    return "HipHop (75–110)"
        case .disco:     return "Disco (105–130)"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .universal: return 75...185
        case .dnb:       return 140...185
        case .psyTrance: return 135...165
        case .house:     return 115...135
        case .hipHop:    return 75...110
        case .disco:     return 105...130
        }
    }

    /// Bringt `bpm` in den Erwartungs-Bereich, indem alle plausiblen Faktoren
    /// (½, 2/3, 1, 1½, 2) durchprobiert und der zum Bereichs-Mittelwert
    /// nächstliegende Kandidat gewählt wird. 1,5× und 2/3× fangen den
    /// häufigen Triolen-/Vierteltakt-Fehler bei aubio ab (typisch in
    /// Psy-Trance: 146 BPM wird als 97,7 erkannt = 146 ÷ 1,5).
    /// Liegt der Originalwert bereits im Bereich, hat er Vorrang — wir
    /// wollen keine zufälligen „Verbesserungen" an plausibel detektierten
    /// Tracks. Liegt kein Kandidat im Bereich, gibt der Originalwert
    /// zurück.
    public func corrected(_ bpm: Double) -> Double {
        guard bpm > 0 else { return bpm }
        let r = range
        if r.contains(bpm) { return bpm }
        let factors: [Double] = [0.5, 2.0 / 3.0, 1.5, 2.0]
        let candidates = factors.map { bpm * $0 }.filter { r.contains($0) }
        guard !candidates.isEmpty else { return bpm }
        let target = (r.lowerBound + r.upperBound) / 2
        return candidates.min(by: { abs($0 - target) < abs($1 - target) }) ?? bpm
    }
}
