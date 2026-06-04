//
//  AudioSessionManager.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import AVFoundation
import Foundation

/// AVAudioSession-Wrapper für iOS: aktiviert die `.playback`-Kategorie
/// idempotent und beobachtet Interruption- und Route-Change-Notifications.
/// Auf macOS gibt es kein Pendant — AVAudioEngine läuft dort ohne explizite
/// Session-Verwaltung.
@MainActor
final class AudioSessionManager {
    private let session = AVAudioSession.sharedInstance()
    private var activated = false
    private var observers: [NSObjectProtocol] = []

    /// Nutzer setzen diese Closures vom `PlayerStore` aus, damit
    /// Interruption-Begin = pause, Interruption-End (mit `.shouldResume`)
    /// = play, Headphones-Abziehen = pause greifen.
    var onInterruptionBegan: (@MainActor () -> Void)?
    var onInterruptionEndedShouldResume: (@MainActor () -> Void)?
    var onShouldPause: (@MainActor () -> Void)?

    init() {
        setupObservers()
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

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

    private func setupObservers() {
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        }
        observers.append(interruption)

        let routeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(note)
            }
        }
        observers.append(routeChange)
    }

    private func handleInterruption(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                onInterruptionEndedShouldResume?()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        // Klassischer „Headphones rausgezogen"-Pfad: iOS schickt
        // .oldDeviceUnavailable, wir pausieren, damit der Sound nicht
        // plötzlich aus dem Lautsprecher kommt.
        if reason == .oldDeviceUnavailable {
            onShouldPause?()
        }
    }
}
