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

    /// Waveform-Daten des aktiven Tracks. `nil` bis der `WaveformCache`
    /// geantwortet hat oder die Berechnung fehlschlug.
    var currentWaveform: WaveformData?
    var isLoadingWaveform: Bool = false

    let engine: AVAudioEnginePlayer

    /// Wird vom AppBootstrap nachträglich gesetzt — kreuzweise Initialisierung
    /// (PlayerStore und NowPlayingManager halten Refs aufeinander).
    weak var nowPlaying: NowPlayingManager?

    private let library: LibraryStore
    private let session: AudioSessionManager
    private let waveformCache: WaveformCache
    private var waveformTask: Task<Void, Never>?

    init(library: LibraryStore, session: AudioSessionManager, waveformCache: WaveformCache) {
        self.engine = AVAudioEnginePlayer()
        self.library = library
        self.session = session
        self.waveformCache = waveformCache

        // Audio-Session-Callbacks verdrahten: Interruption pausiert,
        // resume bei .shouldResume, Headphones-Abzug pausiert.
        session.onInterruptionBegan = { [weak self] in self?.pause() }
        session.onInterruptionEndedShouldResume = { [weak self] in self?.play() }
        session.onShouldPause = { [weak self] in self?.pause() }
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
            loadWaveform(for: track.url)
            nowPlaying?.update()
            // Markiert die Datei im TagLibTrackStore als aktiv → parallele
            // Tag-Writes auf diesen Track werden serialisiert (gequeued bis
            // zum nächsten Track-Wechsel).
            Task { await library.setActiveTrack(track.url) }
        } catch {
            lastError = "Konnte Track nicht laden: \(error.localizedDescription)"
        }
    }

    /// Primärer Play-Pfad. Wird auch aus Lock-Screen / AirPods-Commands +
    /// Interruption-End aufgerufen.
    func play() {
        guard currentTrack != nil else { return }
        if !engine.isPlaying { engine.play() }
        nowPlaying?.update()
    }

    /// Primärer Pause-Pfad. Wird aus Lock-Screen / AirPods + Interruption-
    /// Begin + Headphones-Abzug aufgerufen.
    func pause() {
        guard engine.isPlaying else { return }
        engine.pause()
        nowPlaying?.update()
    }

    /// Holt Waveform-Daten aus dem Cache (Memory → SQLite → vDSP-FFT).
    /// Cancelt einen laufenden Task, falls der Nutzer schnell den Track
    /// wechselt — sonst landet die alte Berechnung noch in `currentWaveform`.
    private func loadWaveform(for url: URL) {
        waveformTask?.cancel()
        currentWaveform = nil
        isLoadingWaveform = true

        waveformTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.waveformCache.waveform(for: url)
                if Task.isCancelled { return }
                guard self.currentTrack?.url == url else { return }
                self.currentWaveform = data
                self.isLoadingWaveform = false
            } catch {
                if self.currentTrack?.url == url {
                    self.isLoadingWaveform = false
                }
            }
        }
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if engine.isPlaying { pause() } else { play() }
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
        nowPlaying?.update()
    }

    /// Setzt das Sterne-Rating auf den aktiven Track und persistiert sofort.
    /// Tap auf den gleichen Sternwert (Toggle-Off in der UI) übergibt 0.
    func setRating(_ stars: Int) {
        guard var track = currentTrack else { return }
        track.rating = Rating(stars: stars)
        currentTrack = track
        nowPlaying?.update()
        Task { await library.updateTrack(track) }
    }

    /// Übernimmt einen komplett bearbeiteten Track aus dem `TagEditSheet`,
    /// aktualisiert die Anzeige im Player und schiebt das Update via
    /// `LibraryStore.updateTrack` in Datei + DB-Cache.
    func applyEdit(_ updated: Track) {
        guard currentTrack?.id == updated.id else { return }
        currentTrack = updated
        nowPlaying?.update()
        Task { await library.updateTrack(updated) }
    }
}
