//
//  PlayerStore.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import Foundation
import Observation
import SetCraftCore
import UIKit

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

    /// URL des Tracks, der gerade auf das Gerät geholt wird — also zwischen
    /// Tap und erstem Ton. Bei einer NAS-Quelle über VPN sind das mehrere
    /// Sekunden; die Library-Zeile zeigt solange einen Spinner.
    var loadingURL: URL?


    /// Anteil der übertragenen Bytes des gerade geladenen Tracks, 0…1.
    /// `nil`, wenn gerade nichts lädt oder die Quelle lokal ist (dann gibt es
    /// nichts zu übertragen). Die Zahl stammt aus der häppchenweisen Kopie —
    /// das Dateisystem gibt für eine FileProvider-Datei keinen Fortschritt her.
    var loadProgress: Double?

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
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    /// Snapshot der Track-Reihenfolge zum Zeitpunkt des letzten manuellen
    /// Tap (oder Folder-Wechsels). Skip Forward/Back folgt dieser Queue,
    /// damit Edits am laufenden Track (z. B. Rating) die Position in der
    /// live-sortierten Liste nicht verschieben und der nächste Tap nicht
    /// zum eben re-sortierten Nachbarn springt.
    private var playbackQueue: [URL] = []

    /// Track, dessen Load daran gescheitert ist, dass das iPhone gesperrt war
    /// und der Share deshalb nichts geliefert hat. Wird beim Entsperren
    /// einmal automatisch nachgeholt.
    private var lockedRetryTrack: Track?

    /// Bis wann dieser Nachhol-Versuch noch erwünscht ist.
    ///
    /// Ohne Frist könnte die App Stunden später beim Entsperren plötzlich
    /// Musik anfangen — iOS stellt einer im Hintergrund suspendierten App
    /// Notifications beim Fortsetzen zu. Eine Viertelstunde deckt den Fall
    /// ab, um den es geht (das Set läuft weiter, der Nutzer holt das Gerät
    /// aus der Tasche), und schliesst den anderen aus.
    private var lockedRetryDeadline: Date?
    private static let lockedRetryWindow: TimeInterval = 15 * 60

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

        // Auto-Advance: läuft ein Track natürlich aus, automatisch
        // den nächsten in der Liste laden. `next()` ist ein No-op,
        // wenn der aktuelle Track das letzte Element ist — in dem Fall
        // muss das NowPlaying-Info aktualisiert werden, sonst bleibt der
        // Lock-Screen-Status (playbackRate=1.0) hängen und zeigt weiter
        // den Pause-Button, obwohl die Engine bereits gestoppt hat.
        engine.onPlaybackEnded = { [weak self] in
            self?.next()
            self?.nowPlaying?.update()
        }

        // Änderungen aus der Bibliothek übernehmen — sonst zeigt der Player
        // weiter den Stand vom Ladezeitpunkt. Betrifft vor allem die Analyse:
        // sie läuft NACH dem Laden und füllt BPM und Key nach.
        library.onTrackChanged = { [weak self] track in
            guard let self, self.currentTrack?.url == track.url else { return }
            self.currentTrack = track
            self.nowPlaying?.update()
        }

        // Beim Entsperren den Track nachholen, der genau daran gescheitert
        // ist. Der Nutzer soll nach dem Griff in die Tasche weiterhören,
        // statt erst eine rote Meldung wegtippen zu müssen.
        ProtectedDataMonitor.shared.onBecameAvailable { [weak self] in
            Task { @MainActor in self?.retryAfterUnlock() }
        }

        // Master-Tempo der letzten Session wiederherstellen. Kein Track
        // geladen — `applyMasterToCurrentTrack` im didSet läuft ins Leere,
        // die Bibliothek bekommt aber sofort den richtigen Anzeige-Zustand.
        if let saved = UserDefaults.standard.object(forKey: "masterBPM") as? Double,
           saved > 0 {
            masterBPM = saved
        }
    }

    var isPlaying: Bool { engine.isPlaying }
    var position: TimeInterval { engine.position }
    var duration: TimeInterval { engine.duration }

    /// Wie `position`, aber bei jedem Zugriff frisch aus `lastRenderTime`
    /// gerechnet statt im 30-Hz-Timer stehengeblieben. Für die Waveform, die
    /// in einer `TimelineView` mit 60 Hz neu zeichnet — sonst ruckelt der
    /// Playhead in Zweier-Schritten und hinkt bis zu 33 ms nach.
    var livePosition: TimeInterval { engine.livePosition }

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

    /// Master-Tempo: jeder geöffnete Track wird auf diese Geschwindigkeit
    /// gezogen. `nil` = aus, dann läuft jeder Track im Original.
    /// Persistiert über App-Sessions, damit ein eingestelltes Set-Tempo den
    /// App-Wechsel überlebt.
    var masterBPM: Double? {
        didSet {
            guard masterBPM != oldValue else { return }
            if let masterBPM {
                UserDefaults.standard.set(masterBPM, forKey: "masterBPM")
            } else {
                UserDefaults.standard.removeObject(forKey: "masterBPM")
            }
            applyMasterToCurrentTrack()
            library.soundingContext = soundingContext
        }
    }

    /// Wiedergabezustand für die Anzeige klingender Tonarten in der Liste.
    var soundingContext: SoundingContext { SoundingContext(masterBPM: masterBPM) }

    /// Klingende Tonart des laufenden Tracks. **Reiner Anzeigewert** — in die
    /// Datei geht immer `track.key`.
    var soundingKey: SoundingKey? {
        guard let key = currentTrack?.key, engine.rate != 1.0 else { return nil }
        return SoundingKey(original: key, rate: engine.rate)
    }

    /// Verhindert, dass die vom Master ausgelöste Ratenänderung das Master
    /// gleich wieder zurückschreibt.
    private var isApplyingMaster = false

    /// Zieht den geladenen Track auf das Master-Tempo. Ohne Master-Tempo oder
    /// ohne bekannte Original-BPM bleibt die Rate, wie sie ist.
    func applyMasterToCurrentTrack() {
        guard let masterBPM, masterBPM > 0,
              let original = currentTrack?.bpm, original > 0
        else { return }
        isApplyingMaster = true
        setRate(masterBPM / original)
        isApplyingMaster = false
    }

    /// CDJ-Span: ±8 % — Fenster der Feinjustage am Slider.
    static let tempoSpan: Double = 0.08

    /// Harte Grenzen des `AVAudioUnitTimePitch`. Die manuelle BPM-Eingabe
    /// klemmt hierauf, damit sich auch ein Set-Tempo weit weg vom Original
    /// des laufenden Tracks setzen lässt.
    static let engineRateMin: Double = 0.5
    static let engineRateMax: Double = 2.0

    /// Lädt einen Track, aktiviert die AVAudioSession (falls noch nicht),
    /// und startet die Wiedergabe direkt — analog zum Autoplay des Macs.
    /// `snapshotQueue: true` (Default für manuelle Taps) friert die aktuelle
    /// Sortierung als Playback-Queue ein; `next()`/`previous()` rufen mit
    /// `false`, damit Skips innerhalb dieser Queue bleiben.
    ///
    /// Synchroner Einstieg, echte Arbeit im Task — genau wie `loadWaveform`.
    /// So bleiben die Aufrufer (Tap in der Liste, Auto-Advance, Skip vom
    /// Lock-Screen) unverändert, während das Warten auf die Datei den
    /// MainActor nicht mehr blockiert.
    func load(_ track: Track, snapshotQueue: Bool = true) {
        // Schneller Track-Wechsel: der vorherige Load hängt womöglich noch
        // am Materialisieren. Abbrechen, sonst überschreibt sein später
        // eintreffendes Ergebnis den neueren Track.
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.performLoad(track, snapshotQueue: snapshotQueue)
        }
    }

    /// Zwei Anläufe, und der zweite ist der eigentliche Punkt.
    ///
    /// Der erste Anlauf spielt aus der lokalen Kopie. Lässt die sich nicht
    /// öffnen, wirft `engine.load` `cachedCopyUnusable` — die Kopie ist dann
    /// bereits verworfen, und der zweite Anlauf holt die Datei neu. Vorher
    /// endete genau dieser Fall mit der roten Meldung „Failed to load track …
    /// com.apple.coreaudio.avfaudio", und zwar bevorzugt beim Auto-Advance:
    /// der Folgetrack kommt aus dem Prefetch, seine Kopie ist also die
    /// einzige, die zwischen Anlegen und Abspielen Zeit hatte, kaputtzugehen.
    ///
    /// Mehr als zwei Anläufe gibt es nicht. Ist die Quelle selbst das Problem,
    /// hilft Wiederholen nicht, und der Nutzer soll das lesen statt zuzusehen.
    private func performLoad(_ track: Track, snapshotQueue: Bool) async {
        lockedRetryTrack = nil
        lockedRetryDeadline = nil
        for attempt in 1...2 {
            let done = await attemptLoad(track, snapshotQueue: snapshotQueue, attempt: attempt)
            if done { return }
        }
    }

    /// Wird gerufen, wenn das iPhone entsperrt wird. Holt genau den einen
    /// Load nach, der an der Sperre gescheitert ist — und nur den, und nur
    /// innerhalb des Zeitfensters.
    private func retryAfterUnlock() {
        guard let track = lockedRetryTrack,
              let deadline = lockedRetryDeadline,
              Date() < deadline
        else {
            lockedRetryTrack = nil
            lockedRetryDeadline = nil
            return
        }
        lockedRetryTrack = nil
        lockedRetryDeadline = nil
        // `snapshotQueue: false` — die Playback-Queue von damals gilt weiter,
        // das hier ist die Fortsetzung desselben Sets, kein neuer Tap.
        load(track, snapshotQueue: false)
    }

    /// Ein Anlauf. `true` = fertig (geladen oder endgültig gescheitert),
    /// `false` = die Kopie war unbrauchbar, bitte noch einmal.
    private func attemptLoad(_ track: Track, snapshotQueue: Bool, attempt: Int) async -> Bool {
        loadingURL = track.url
        lastError = nil
        loadProgress = nil

        // Datei ggf. erst auf das Gerät holen. Betrifft iCloud-Platzhalter
        // genauso wie Tracks von einem SMB/NAS-Share aus der Files-App:
        // beide kommen über den FileProvider, und `AVAudioFile` würde beim
        // Öffnen blockieren, bis die Datei vollständig da ist.
        //
        // Der Platzhalter-Check samt Download-Anstoss liegt bewusst IN
        // `prefetch` — er fragt Resource-Values beim Provider ab und blockiert
        // damit selbst. Hier stand er bis 2026-09-19 vor dem ersten `await`
        // und hielt im Flugmodus das ganze UI an.
        //
        // Schlägt das Materialisieren fehl (Flugmodus, NAS nicht erreichbar,
        // nur halb übertragene Datei), endet der Load hier MIT Meldung. Vorher
        // wurden beide Fehlerquellen verschluckt: die Engine bekam die Datei
        // trotzdem, spielte sichtbar los und blieb stumm.
        do {
            try await AVAudioEnginePlayer.prefetch(url: track.url) { [weak self] fraction in
                Task { @MainActor in
                    // Nur für den Track, der gerade geladen wird — ein spät
                    // eintreffender Fortschritt eines abgehängten Loads darf
                    // die Anzeige nicht mehr anfassen.
                    guard let self, self.loadingURL == track.url else { return }
                    self.loadProgress = fraction
                }
            }
        } catch {
            guard !Task.isCancelled, loadingURL == track.url else { return true }
            loadingURL = nil
            loadProgress = nil
            // Der Flugmodus-Fall bekommt einen eigenen Satz. „Failed to load
            // track: The operation couldn’t be completed." sagt dem Nutzer
            // nichts — dass das Gerät offline ist, sagt ihm alles.
            if case AudioEngineError.sourceOffline = error {
                lastError = String(localized: "The source is not reachable — the device is offline and this track is not stored locally.")
            } else if !UIApplication.shared.isProtectedDataAvailable {
                // Hier und nur hier abgefragt: im Moment des Fehlschlags. Wer
                // die Meldung später liest, hat das iPhone längst entsperrt.
                lastError = String(localized: "The source could not be read while the iPhone was locked, and this track was not prefetched.")
                // Beim Entsperren noch einmal versuchen — dann kann
                // `smbclientd` die Zugangsdaten des Shares wieder aus dem
                // Keychain lesen und die Session neu aufbauen.
                lockedRetryTrack = track
                lockedRetryDeadline = Date().addingTimeInterval(Self.lockedRetryWindow)
            } else {
                lastError = String(localized: "Failed to load track: \(error.localizedDescription)")
            }
            return true
        }

        // Währenddessen kann ein neuerer Tap dazwischengekommen sein — dann
        // gehört die Anzeige bereits ihm, und wir treten kommentarlos ab.
        guard !Task.isCancelled, loadingURL == track.url else { return true }
        loadingURL = nil
        loadProgress = nil

        do {
            try session.activate()
            try engine.load(url: track.url)
            engine.rate = 1.0   // frisches Tempo pro Track — Vorgänger-Rate verwerfen
            currentTrack = track
            // Master-Tempo zieht den neuen Track direkt auf Set-Geschwindigkeit.
            applyMasterToCurrentTrack()
            lastError = nil
            if snapshotQueue {
                playbackQueue = library.tracks.map(\.url)
            }
            engine.play()
            // Quelle warmhalten, solange aus ihr gespielt wird — sonst lässt
            // `smbclientd` die SMB-Session nach zwei Minuten Leerlauf fallen
            // und kann sie bei gesperrtem Gerät nicht wieder aufbauen.
            SourceKeepAlive.shared.start(for: track.url)
            loadWaveform(for: track.url)
            nowPlaying?.update()
            // BPM und Key berechnen, falls sie nicht in den Tags stehen —
            // die Regel aus CLAUDE.md. Fehlte auf iOS bis 2026-09-20; der
            // Mac macht das beim Laden seit jeher.
            library.analyzeIfNeeded(track)
            // Nächsten Track schon holen, während dieser läuft.
            prefetchNeighbor()
            // Markiert die Datei im TagLibTrackStore als aktiv → parallele
            // Tag-Writes auf diesen Track werden serialisiert (gequeued bis
            // zum nächsten Track-Wechsel).
            Task { await library.setActiveTrack(track.url) }
            // Play-Count +1 für jeden Track-Load. Auto-Advance (snapshotQueue=
            // false) zählt bewusst auch — der Track wurde tatsächlich
            // abgespielt; das entspricht der Mac-Logik.
            library.notePlay(forURL: track.url)
            return true
        } catch AudioEngineError.cachedCopyUnusable where attempt == 1 {
            // Die kaputte Kopie ist weg. Noch einmal von vorn — der Prefetch
            // legt sie neu an, und der zweite Anlauf spielt daraus.
            return false
        } catch {
            lastError = String(localized: "Failed to load track: \(error.localizedDescription)")
            return true
        }
    }

    /// Holt den nächsten Track der Queue auf das Gerät, während der aktuelle
    /// noch läuft. Über Mobilfunk/VPN ist das der Unterschied zwischen
    /// nahtlosem Auto-Advance und mehreren Sekunden Stille am Trackende.
    ///
    /// Läuft mit Hintergrund-Priorität und ohne Ergebnis: schlägt der
    /// Prefetch fehl, merkt das niemand — `performLoad` holt die Datei dann
    /// eben beim Laden selbst.
    ///
    /// `cancel()` greift hier wirklich: die Vorausschau läuft auf einer
    /// eigenen seriellen Queue, und wer abgehängt wird, bevor er dran war,
    /// überträgt kein einziges Byte. Beim schnellen Durchskippen bleibt es
    /// so bei zwei Downloads statt einem pro übersprungenem Track.
    private func prefetchNeighbor() {
        prefetchTask?.cancel()
        let urls = (1...Self.lookaheadDepth).compactMap { neighborInQueue(offset: $0)?.url }
        guard !urls.isEmpty else { return }
        prefetchTask = Task.detached(priority: .background) {
            // Der Reihe nach, nicht nebenläufig: die Vorausschau läuft ohnehin
            // auf einer seriellen Queue, und so kommt der Track, der als
            // nächstes dran ist, auch als erster an. Zwischen zwei Dateien
            // greift ausserdem der Abbruch — beim Durchskippen überträgt eine
            // abgehängte Vorausschau dann keine ganze Datei mehr umsonst.
            for url in urls {
                if Task.isCancelled { return }
                await AVAudioEnginePlayer.prefetchAhead(url: url)
            }
        }
    }

    /// Wie viele Tracks im Voraus auf das Gerät geholt werden. Deckt sich mit
    /// der Kapazität des `PlaybackCache` (laufender Track + diese acht).
    ///
    /// Drei statt einem seit dem Auto-Fahrt-Befund vom 2026-09-20: bei
    /// gesperrtem Gerät liefert der FileProvider nicht, die Wiedergabe reicht
    /// also genau so weit wie die bereitliegenden Kopien.
    ///
    /// Acht statt drei seit dem 2026-09-21: vier Kopien trugen im Test genau
    /// zwanzig Minuten, dann stand die Wiedergabe. Acht decken rund
    /// fünfundvierzig. Der Preis ist Vorab-Traffic, der im Zweifel umsonst
    /// war — er fällt im Hintergrund an, auf der `.utility`-Queue, und ein
    /// Skip hängt die Vorausschau zwischen zwei Dateien ab.
    ///
    /// Das Nachladen bleibt trotzdem nötig: bei jedem Track-Wechsel läuft die
    /// Vorausschau neu und füllt auf, sobald die Quelle wieder antwortet.
    /// Bereits vorhandene Kopien kosten dabei nur einen `stat`.
    private static let lookaheadDepth = 8


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
                // Zwischenstände: die Welle wächst mit dem Dekodieren mit,
                // statt bis zum Ende der Analyse leer zu bleiben. Aus dem
                // Cache kommt sofort ein einziger, vollständiger Stand.
                for try await update in self.waveformCache.stream(for: url) {
                    if Task.isCancelled { return }
                    guard self.currentTrack?.url == url else { return }
                    // Verspätete Zwischenstände nie hinter den bereits
                    // gezeigten Stand zurückfallen lassen.
                    if let existing = self.currentWaveform,
                       update.bins.count < existing.bins.count,
                       !update.isComplete {
                        continue
                    }
                    self.currentWaveform = update
                    self.isLoadingWaveform = !update.isComplete
                }
                if self.currentTrack?.url == url {
                    self.isLoadingWaveform = false
                }
            } catch {
                if self.currentTrack?.url == url {
                    self.isLoadingWaveform = false
                }
            }
        }
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        // Eine stehengebliebene Meldung des letzten Ladeversuchs hat sich
        // erledigt, sobald der Nutzer selbst wieder Hand anlegt — sonst
        // klebt sie unter einem Track, der längst wieder spielt.
        lastError = nil
        // Der Nutzer hat selbst eingegriffen — ein automatischer Nachhol-
        // Versuch beim nächsten Entsperren wäre jetzt nur noch Überraschung.
        lockedRetryTrack = nil
        lockedRetryDeadline = nil
        if engine.isPlaying { pause() } else { play() }
    }

    func next() {
        guard let target = neighborInQueue(offset: 1) else { return }
        load(target, snapshotQueue: false)
    }

    func previous() {
        guard let target = neighborInQueue(offset: -1) else { return }
        load(target, snapshotQueue: false)
    }

    /// Liefert den Track an Position `offset` relativ zum aktuell laufenden
    /// in der `playbackQueue`. URL-Match wie zuvor — Track.id wechselt beim
    /// Cache-Read. Fallback auf `library.tracks`, falls die Queue noch
    /// nie gefüllt wurde (etwa AirPods-Skip direkt nach App-Start).
    private func neighborInQueue(offset: Int) -> Track? {
        guard let current = currentTrack else { return nil }
        let queue = playbackQueue.isEmpty
            ? library.tracks.map(\.url)
            : playbackQueue
        guard let idx = queue.firstIndex(of: current.url) else { return nil }
        let next = idx + offset
        guard next >= 0, next < queue.count else { return nil }
        return library.tracks.first(where: { $0.url == queue[next] })
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
        nowPlaying?.update()
    }

    /// Setzt die Wiedergabe-Rate direkt (für den Slider im Tempo-Sheet).
    /// Klemmt auf 0.5…2.0; das Now-Playing-Center bekommt den neuen
    /// `playbackRate`, damit der Lock-Screen-Scrubber synchron läuft.
    ///
    /// Ist das Master-Tempo aktiv, wandert es mit: die Tempoänderung im
    /// Player setzt dann das Set-Tempo für alle folgenden Tracks. Ist es
    /// aus, gilt die Änderung nur für den laufenden Track.
    func setRate(_ rate: Double) {
        engine.rate = max(Self.engineRateMin, min(Self.engineRateMax, rate))
        if !isApplyingMaster, masterBPM != nil,
           let original = currentTrack?.bpm, original > 0 {
            masterBPM = original * engine.rate
        }
        nowPlaying?.update()
    }

    /// Schaltet das Master-Tempo ein oder aus. Beim Einschalten wird das
    /// gerade klingende Tempo des laufenden Tracks zum Master — so wie am
    /// Mac der „global"-Schalter am Tempo-Chip.
    func setMasterEnabled(_ enabled: Bool) {
        guard enabled else {
            masterBPM = nil
            return
        }
        masterBPM = effectiveBPM ?? currentTrack?.bpm
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
