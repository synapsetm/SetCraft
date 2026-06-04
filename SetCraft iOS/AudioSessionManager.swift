//
//  AudioSessionManager.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import AVFoundation
import Foundation

/// Minimaler AVAudioSession-Wrapper für iOS. Aktiviert die `.playback`-
/// Kategorie vor dem ersten Sound. Auf macOS gibt es kein Pendant —
/// AVAudioEngine läuft dort ohne explizite Session-Verwaltung.
@MainActor
final class AudioSessionManager {
    private let session = AVAudioSession.sharedInstance()
    private var activated = false

    /// Idempotent: mehrfach aufrufbar, aktiviert die Session nur beim
    /// ersten Mal.
    func activate() throws {
        guard !activated else { return }
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
        activated = true
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        activated = false
    }
}
