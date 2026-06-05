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

    /// `true` solange BPM- bzw. Key-Analyse für den aktuell geladenen Track
    /// läuft — der Player liest das, um in BPM- und Key-Chip einen Spinner
    /// statt des „—"-Platzhalters zu zeigen.
    var isAnalyzingCurrentTrack: Bool {
        guard let id = currentTrack?.id else { return false }
        return library.isAnalyzing(trackID: id)
    }
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

    /// Aktuelle Wiedergabe-Rate (1.0 = original). ±8 % typischer DJ-Bereich;
    /// AVAudioUnitTimePitch klemmt hart auf 0.5…2.0.
    var currentRate: Double { engine.rate }

    /// Tempo-Hub für die BPM-Anzeige im Chip: Original × Rate. Wenn der
    /// Track keinen Tag-BPM hat, kann auch kein effektiver Wert berechnet
    /// werden — Chip zeigt dann "—".
    var effectiveBPM: Double? {
        guard let bpm = currentTrack?.bpm else { return nil }
        return bpm * engine.rate
    }

    /// CDJ-Span: ±8 % rund um 1.0 — sowohl Slider als auch BPM-Manual-Eingabe
    /// werden auf dieses Fenster geklemmt.
    static let tempoSpan: Double = 0.08

    /// Lädt einen Track, aktiviert die AVAudioSession (falls noch nicht),
    /// und startet die Wiedergabe direkt — analog zum Autoplay des Macs.
    func load(_ track: Track) {
        // iCloud-Datei, die noch nicht runtergeladen ist: AVAudioFile würde
        // mit kryptischem Fehler abbrechen. Download anstoßen, klaren
        // Hinweis zeigen — Nutzer triggert das Laden noch mal, sobald die
        // Datei lokal ist.
        if !isLocallyAvailable(track.url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: track.url)
            lastError = String(localized: "Track is loading from iCloud — try again in a moment.")
            return
        }
        do {
            try session.activate()
            try engine.load(url: track.url)
            engine.rate = 1.0   // frisches Tempo pro Track — Vorgänger-Rate verwerfen
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
            lastError = String(localized: "Failed to load track: \(error.localizedDescription)")
        }
    }

    private func isLocallyAvailable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard let values, values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
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

    /// Setzt die Wiedergabe-Rate direkt (für den Slider im Tempo-Sheet).
    /// Klemmt auf 0.5…2.0; das Now-Playing-Center bekommt den neuen
    /// `playbackRate`, damit der Lock-Screen-Scrubber synchron läuft.
    func setRate(_ rate: Double) {
        engine.rate = max(0.5, min(2.0, rate))
        nowPlaying?.update()
    }

    /// Setzt das Tempo so, dass der Track auf das angegebene Ziel-BPM
    /// gestreckt wird (Rate = target / original). Erfordert dass der Track
    /// einen Original-BPM-Tag hat, sonst ein No-op.
    func setTargetBPM(_ bpm: Double) {
        guard let original = currentTrack?.bpm, original > 0 else { return }
        setRate(bpm / original)
    }

    /// Tempo zurück auf 1.0 (Reset-Button im Sheet).
    func resetTempo() {
        setRate(1.0)
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
