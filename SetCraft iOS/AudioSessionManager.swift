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
        // KRITISCH: Swift 6 erlaubt nicht, `Notification` (non-Sendable) in
        // einen @Sendable-Task-Closure zu capturen. Daher die relevanten
        // Werte SYNCHRON aus `userInfo` ziehen — der Observer-Callback läuft
        // bereits auf .main — und nur die UInt-Scalars in den MainActor-Task
        // weiterreichen.
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        }
        observers.append(interruption)

        let routeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(rawReason: rawReason)
            }
        }
        observers.append(routeChange)
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                onInterruptionEndedShouldResume?()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard let rawReason,
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
