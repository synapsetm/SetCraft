//
//  PlayerStore.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import Foundation
import Observation
import SetCraftCore

/// iOS-Pendant zum Mac-`PlayerViewModel`. Hält den `AVAudioEnginePlayer`,
/// den aktuell geladenen Track und kennt die `LibraryStore`-Trackliste,
/// um Prev/Next innerhalb der aktuellen Quelle anbieten zu können.
@Observable
@MainActor
final class PlayerStore {
    var currentTrack: Track?
    var lastError: String?

    let engine: AVAudioEnginePlayer

    private let library: LibraryStore
    private let session: AudioSessionManager

    init(library: LibraryStore, session: AudioSessionManager) {
        self.engine = AVAudioEnginePlayer()
        self.library = library
        self.session = session
    }

    var isPlaying: Bool { engine.isPlaying }
    var position: TimeInterval { engine.position }
    var duration: TimeInterval { engine.duration }

    /// Lädt einen Track, aktiviert die AVAudioSession (falls noch nicht),
    /// und startet die Wiedergabe direkt — analog zum Autoplay des Macs.
    func load(_ track: Track) {
        do {
            try session.activate()
            try engine.load(url: track.url)
            currentTrack = track
            lastError = nil
            engine.play()
        } catch {
            lastError = "Konnte Track nicht laden: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
    }

    func next() {
        guard let current = currentTrack,
              let idx = library.tracks.firstIndex(where: { $0.id == current.id }),
              idx + 1 < library.tracks.count
        else { return }
        load(library.tracks[idx + 1])
    }

    func previous() {
        guard let current = currentTrack,
              let idx = library.tracks.firstIndex(where: { $0.id == current.id }),
              idx > 0
        else { return }
        load(library.tracks[idx - 1])
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
    }
}
