import Foundation
import Observation
import SetCraftCore

/// Hält die Tempo-/Key-Anzeige über alle Tracks hinweg: Original- und
/// effektive Werte des gerade geladenen Tracks plus den optionalen
/// Master-BPM, der auf jeden neu geladenen Track angewendet wird.
///
/// Hinweis: Die Möglichkeit, den Key zu verändern, wurde absichtlich entfernt.
/// `effectiveKey` zeigt nur an, was sich aus dem Original-Tag und einem
/// eventuellen Pitch-Offset ergibt — gesetzt wird er nicht mehr.
@MainActor
@Observable
final class TransportViewModel {

    /// Erlaubter Tempo-Bereich um 1.0 herum, ±8 % (CDJ-Standard).
    static let tempoSpan: Double = 0.08

    /// Maximum, das die Engine hart limitiert (AVAudioUnitTimePitch: 0.5–2.0).
    static let engineRateMin: Double = 0.5
    static let engineRateMax: Double = 2.0

    private weak var player: PlayerViewModel?

    init(player: PlayerViewModel) {
        self.player = player
    }

    // MARK: - Master-State

    var masterBPM: Double? = nil
    var isGlobalBPM: Bool = false

    // MARK: - Effektiv geltende Werte (für UI-Anzeige)

    var effectiveBPM: Double? {
        guard let rate = currentRate, let original = player?.originalBPM else {
            return nil
        }
        return original * rate
    }

    var effectiveKey: CamelotKey? {
        guard let original = player?.originalKey else { return nil }
        let cents = Int(player?.player.pitchCents ?? 0)
        let semitones = Int((Double(cents) / 100.0).rounded())
        return original.nudged(bySemitones: semitones)
    }

    var currentRate: Double? {
        guard player?.player.loadedURL != nil else { return nil }
        return player?.player.rate
    }

    var originalBPM: Double? { player?.originalBPM }
    var originalKey: CamelotKey? { player?.originalKey }
    var hasLoadedTrack: Bool { player?.player.loadedURL != nil }

    // MARK: - Apply

    /// Wendet die aktuell hinterlegten Master-Werte auf den aktuell geladenen
    /// Track an. Wird aus `ContentView.onChange(loadedURL)` aufgerufen.
    func applyMasterToLoadedTrack() {
        guard let player else { return }
        guard player.player.loadedURL != nil else { return }
        applyMasterBPM()
    }

    private func applyMasterBPM() {
        guard let player else { return }
        guard isGlobalBPM, let target = masterBPM, let original = player.originalBPM, original > 0 else {
            return
        }
        let rate = clampRate(target / original)
        player.player.rate = rate
    }

    // MARK: - User-Eingaben am Tempo-Chip

    /// Setzt das gewünschte BPM des aktuellen Tracks. Wenn `isGlobalBPM`, wird
    /// der Wert zusätzlich zum neuen Master-BPM.
    func setBPM(_ bpm: Double) {
        guard let player, let original = player.originalBPM, original > 0 else { return }
        let rate = clampRate(bpm / original)
        player.player.rate = rate
        if isGlobalBPM {
            masterBPM = bpm
        }
    }

    /// Setzt direkt eine Rate (für den ±8 %-Slider).
    func setRate(_ rate: Double) {
        guard let player else { return }
        player.player.rate = clampRate(rate)
        if isGlobalBPM, let original = player.originalBPM {
            masterBPM = original * player.player.rate
        }
    }

    func setIsGlobalBPM(_ enabled: Bool) {
        isGlobalBPM = enabled
        if enabled, let bpm = effectiveBPM {
            masterBPM = bpm
        } else if !enabled {
            masterBPM = nil
        }
    }

    // MARK: - Helpers

    private func clampRate(_ rate: Double) -> Double {
        max(Self.engineRateMin, min(Self.engineRateMax, rate))
    }
}
