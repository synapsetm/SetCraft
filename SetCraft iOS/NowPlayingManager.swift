//
//  NowPlayingManager.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import Foundation
import MediaPlayer
import UIKit
import SetCraftCore

/// Verdrahtet den `MPRemoteCommandCenter` (Play/Pause/Prev/Next/Scrub aus
/// Lock-Screen, Control-Center, AirPods, CarPlay) mit dem `PlayerStore` und
/// hält `MPNowPlayingInfoCenter.default().nowPlayingInfo` aktuell. Auf
/// macOS irrelevant — wird nur vom iOS-Target verwendet.
@MainActor
final class NowPlayingManager {
    private let player: PlayerStore
    private var lastArtworkURL: URL?
    private var artworkTask: Task<Void, Never>?

    init(player: PlayerStore) {
        self.player = player
        setupCommands()
    }

    /// Wird vom `PlayerStore` nach jeder Zustandsänderung (load, play, pause,
    /// seek, applyEdit) aufgerufen. Position + Rate werden gesetzt, der
    /// System-Extrapolator zeichnet den Scrubber dazwischen selbst.
    func update() {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = player.currentTrack else {
            // Kein Track geladen → Now-Playing-Eintrag entfernen, sonst
            // bleibt der vorherige Track samt Play/Pause-Button auf dem
            // Lock-Screen sichtbar.
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.displayTitle
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? player.currentRate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        center.nowPlayingInfo = info
        // `playbackState` ist die maßgebliche Quelle für den Play/Pause-Button
        // auf Lock-Screen und Control-Center. Ohne explizites Setzen kann iOS
        // den Button auf dem alten Wert „kleben" lassen, obwohl
        // `playbackRate` im Info-Dict bereits auf 0 steht.
        center.playbackState = player.isPlaying ? .playing : .paused

        // Artwork nur bei Track-Wechsel neu laden — vermeidet redundante
        // ArtworkReader-Aufrufe bei jedem Play/Pause/Seek.
        let currentURL = player.currentTrack?.url
        if currentURL != lastArtworkURL {
            lastArtworkURL = currentURL
            artworkTask?.cancel()
            if let url = currentURL {
                artworkTask = Task { [weak self] in
                    await self?.loadAndApplyArtwork(url: url)
                }
            }
        }
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastArtworkURL = nil
        artworkTask?.cancel()
    }

    /// Baut das Artwork-Objekt bewusst **ausserhalb** der MainActor-Isolation.
    ///
    /// `MPMediaItemArtwork` ruft seinen Request-Handler auf einer eigenen Queue
    /// auf — beim Zusammenbauen des Now-Playing-Dictionaries, also bei jedem
    /// Trackwechsel. Der Handler-Typ ist nicht `@Sendable`, und wird er in
    /// einem MainActor-isolierten Kontext gebildet, erbt er diese Isolation.
    /// Im Swift-6-Sprachmodus prüft die Runtime das beim Aufruf
    /// (`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue`); die Prüfung
    /// schlägt fehl, weil MediaPlayer eben nicht auf dem Main-Thread fragt.
    /// Ergebnis: `EXC_BREAKPOINT`, App weg. Genau das ist in 1.3-21 passiert
    /// (zwei Crash-Reports vom 2026-09-20, beide beim Trackwechsel).
    ///
    /// In einer `nonisolated` Funktion gebildet, trägt der Handler keine
    /// Isolation und darf von jeder Queue gerufen werden.
    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadAndApplyArtwork(url: URL) async {
        let data = await ArtworkReader.loadArtwork(url: url)
        if Task.isCancelled { return }
        guard let data, let image = UIImage(data: data) else { return }
        // Track könnte zwischenzeitlich gewechselt haben — verwerfen.
        guard player.currentTrack?.url == url else { return }

        let artwork = Self.makeArtwork(from: image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard self.player.currentTrack != nil else { return .noActionableNowPlayingItem }
            self.player.play()
            return .success
        }

        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.pause()
            return .success
        }

        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard self.player.currentTrack != nil else { return .noActionableNowPlayingItem }
            self.player.togglePlayPause()
            return .success
        }

        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.next()
            return .success
        }

        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.previous()
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.player.seek(to: positionEvent.positionTime)
            return .success
        }
    }
}
