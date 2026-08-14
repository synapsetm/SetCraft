import Foundation

/// Umrechnungen zwischen Wiedergabegeschwindigkeit und Tonhöhe.
///
/// Ohne Key-Lock verschiebt eine Tempoänderung zwangsläufig die Tonhöhe —
/// schnelleres Abspielen hebt alle Frequenzen im selben Verhältnis an.
/// Faustregel: ~6 % Tempoänderung entsprechen einem Halbton.
public enum PitchMath {

    /// Halbtonverschiebung aus dem Geschwindigkeitsverhältnis
    /// (`rate` = Ziel-BPM / Original-BPM).
    public static func semitoneShift(forRate rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        return 12 * log2(rate)
    }

    /// Cents für `AVAudioUnitTimePitch.pitch` (100 Cents = 1 Halbton).
    public static func cents(forRate rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        return 1200 * log2(rate)
    }

    /// Umkehrung: nötige Rate für `n` Halbtöne.
    public static func rate(forSemitones n: Double) -> Double {
        pow(2, n / 12)
    }
}

/// Der klingende Key eines Tracks bei laufender Tempoänderung ohne Key-Lock.
///
/// **Reiner Laufzeitwert.** Wird nie in Datei-Tags oder in den SQLite-Cache
/// geschrieben — dort steht ausschliesslich der analysierte Original-Key.
/// Siehe `SPEC.md` §5b und die Pflichtregel in `CLAUDE.md`.
public struct SoundingKey: Equatable, Sendable {

    /// Ab diesem Rundungsabstand gilt der klingende Key als Grenzfall: der
    /// Track liegt hörbar „zwischen" zwei Tonarten und die Rundung ist
    /// willkürlich. Startwert aus `SPEC.md` §5b, mit echter Library
    /// nachzujustieren.
    public static let ambiguityThreshold = 0.40

    /// Der analysierte Key aus Tag/Analyse — unverändert.
    public let original: CamelotKey
    /// Der bei der aktuellen Rate tatsächlich klingende Key.
    public let sounding: CamelotKey
    /// Gerundete Halbtonverschiebung.
    public let semitones: Int
    /// Ungerundete Verschiebung, für die Grenzfall-Prüfung.
    public let exactSemitones: Double

    public init(original: CamelotKey, rate: Double) {
        self.original = original
        self.exactSemitones = PitchMath.semitoneShift(forRate: rate)
        let rounded = Int(exactSemitones.rounded())
        self.semitones = rounded
        self.sounding = original.nudged(bySemitones: rounded)
    }

    /// `true`, wenn sich die Tonart hörbar verschoben hat.
    public var isShifted: Bool { semitones != 0 }

    /// `true`, wenn der Track zwischen zwei Tonarten liegt und die Anzeige
    /// deshalb mit einer Tilde relativiert werden sollte (`~9A`).
    public var isAmbiguous: Bool {
        abs(exactSemitones - exactSemitones.rounded()) > Self.ambiguityThreshold
    }
}

extension Track {

    /// Rate, mit der dieser Track bei gesetzter Master-BPM abgespielt wird.
    /// `nil`, wenn keine Master-BPM aktiv ist oder der Track keine eigene
    /// BPM hat — dann gibt es nichts zu verschieben.
    public func playingRate(masterBPM: Double?) -> Double? {
        guard let masterBPM, masterBPM > 0,
              let bpm, bpm > 0
        else { return nil }
        return masterBPM / bpm
    }

    /// Die BPM, mit der der Track gerade klingt.
    ///
    /// **Nie persistieren** — in die Datei geht immer `bpm`.
    public func playingBPM(masterBPM: Double?) -> Double? {
        guard let rate = playingRate(masterBPM: masterBPM) else { return bpm }
        guard let bpm else { return nil }
        return bpm * rate
    }

    /// Der Key, mit dem der Track gerade klingt.
    ///
    /// Gibt `nil` zurück, wenn die Verschiebung nicht greift: bei aktivem
    /// Key-Lock (Tonhöhe bleibt konstant), ohne Master-BPM oder ohne
    /// analysierten Key. Der Aufrufer zeigt dann den Original-Key.
    ///
    /// **Nie persistieren** — in die Datei geht immer `key`.
    public func playingKey(masterBPM: Double?, keyLock: Bool) -> SoundingKey? {
        guard !keyLock,
              let key,
              let rate = playingRate(masterBPM: masterBPM)
        else { return nil }
        return SoundingKey(original: key, rate: rate)
    }

    /// Sortierschlüssel für die Key-Spalte: bei ausgeschaltetem Key-Lock der
    /// klingende, sonst der getaggte Key. Tracks ohne Key sortieren ans Ende.
    public func keySortValue(masterBPM: Double?, keyLock: Bool) -> Int {
        let effective = playingKey(masterBPM: masterBPM, keyLock: keyLock)?.sounding ?? key
        guard let effective else { return Int.max }
        // Nach Camelot-Zahl gruppieren, Mode als Nebenschlüssel — so stehen
        // harmonisch benachbarte Tracks beieinander.
        return effective.number * 2 + (effective.mode == .major ? 1 : 0)
    }
}
