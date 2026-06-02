import Foundation

public struct CamelotKey: Hashable, Sendable, CustomStringConvertible {
    public enum Mode: String, Sendable, Hashable {
        case minor = "A"
        case major = "B"
    }

    public let number: Int
    public let mode: Mode

    public init?(number: Int, mode: Mode) {
        guard (1...12).contains(number) else { return nil }
        self.number = number
        self.mode = mode
    }

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = trimmed.last,
              let mode = Mode(rawValue: String(last)),
              let n = Int(trimmed.dropLast())
        else { return nil }
        self.init(number: n, mode: mode)
    }

    public var description: String { "\(number)\(mode.rawValue)" }

    // MARK: - Halbton-Mathe

    /// Position der Tonika auf der chromatischen Skala (C = 0, B = 11).
    /// Wird über den Quintenzirkel berechnet — jede Camelot-Nachbarschaft
    /// entspricht 7 Halbtönen.
    public var tonicChromatic: Int {
        let anchor = (mode == .major) ? 8 : 5    // 8B = C-Dur = 0, 5A = c-Moll = 0
        let raw = (7 * (number - anchor)) % 12
        return raw >= 0 ? raw : raw + 12
    }

    /// Halbton-Distanz zu `other`, gewählt im Bereich −5…+6 (kürzester Weg).
    /// Gibt `nil` zurück, wenn die Modes (Dur/Moll) unterschiedlich sind —
    /// Pitch-Shift ändert nur die Tonhöhe, nicht den Mode, daher ist eine
    /// echte Anpassung quer über die Modes nicht möglich.
    public func semitoneShift(to other: CamelotKey) -> Int? {
        guard mode == other.mode else { return nil }
        let raw = (other.tonicChromatic - tonicChromatic + 12) % 12
        return raw > 6 ? raw - 12 : raw
    }

    /// Verschiebt den Schlüssel um `semitones` (in beide Richtungen) auf der
    /// chromatischen Skala. Der Mode bleibt erhalten.
    public func nudged(bySemitones semitones: Int) -> CamelotKey {
        let target = ((tonicChromatic + semitones) % 12 + 12) % 12
        let anchor = (mode == .major) ? 8 : 5
        // Inverse von tonicChromatic: target = 7*(n - anchor) mod 12
        //   → n - anchor ≡ 7 * target (mod 12)  weil 7·7 ≡ 1 (mod 12)
        let n = ((anchor - 1 + 7 * target) % 12) + 1
        return CamelotKey(number: n, mode: mode) ?? self
    }
}
