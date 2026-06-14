import AppKit
import Foundation
import Observation
import SetCraftCore

@Observable
final class LibraryViewModel {
    enum AnalysisState: Sendable {
        case idle
        case scheduled
        case done
        case failed
    }

    var tracks: [Track] = []
    var folderURL: URL?
    var isScanning = false
    var selectedTrackID: Track.ID?
    var lastWriteError: String?
    var lastAnalysisError: String?
    var lastLibraryError: String?

    /// Liste aller persistierten Quellen (Ordner). Wird beim App-Start
    /// aus der DB geladen.
    var folders: [FolderRecord] = []

    /// ID des aktuell angezeigten Ordners. Schaltet beim Wechsel den
    /// `tracks`-Inhalt um.
    var selectedFolderID: String?

    /// Aktuell aktive Sortierreihenfolge. Default: Titel A→Z. Mehrere
    /// Comparators sind möglich (z. B. Artist → Album → Titel).
    /// `tracks` wird **nicht** automatisch nachgezogen, wenn sich ein Tag
    /// ändert — sonst springt der gerade editierte Eintrag aus dem Sichtfeld.
    /// Re-Sort passiert nur bei expliziten Anlässen: Spalten-Klick (siehe
    /// `LibraryView.onChange(sortOrder)`), `refresh()`-Button und nach
    /// einem abgeschlossenen Scan (`applySortOrder` am Ende von `scan`).
    var sortOrder: [KeyPathComparator<Track>] = [
        KeyPathComparator(\Track.title, order: .forward)
    ]

    /// Re-sortiert `tracks` in-place mit der aktuellen `sortOrder`. Wird
    /// vom Refresh-Button, beim Wechsel der Sortierspalte und am Ende
    /// eines Scans aufgerufen.
    func applySortOrder() {
        tracks.sort(using: sortOrder)
    }

    /// IDs der Tracks mit Änderungen, die noch nicht auf der Platte sind.
    /// Erst nach erfolgreichem `save` wird die ID hier wieder entfernt.
    var unsavedTrackIDs: Set<Track.ID> = []

    var hasUnsavedChanges: Bool { !unsavedTrackIDs.isEmpty }

    /// Welcher Track aktuell analysiert wird (oder bereits analysiert wurde).
    var analysisState: [Track.ID: AnalysisState] = [:]

    /// Wahl des erwarteten BPM-Bereichs für die Oktav-Korrektur.
    var bpmPreset: BPMRangePreset = .universal

    var pendingAnalysisCount: Int {
        analysisState.values.lazy.filter { $0 == .scheduled }.count
    }

    /// Wird nach jeder abgeschlossenen Analyse mit dem aktualisierten Track
    /// gerufen. ContentView verdrahtet das so, dass der PlayerViewModel
    /// seine originalBPM/originalKey nachzieht, wenn der Analysetrack gerade
    /// geladen ist — sonst zeigen die Player-Chips weiter "—".
    var onTrackAnalyzed: ((Track) -> Void)?

    private let repository: LibraryRepository
    private let database: DatabaseService
    private let analyzer = AnalysisCoordinator()
    private let waveformCache: WaveformCache
    private var scanTask: Task<Void, Never>?
    private var pendingSaves: [Track.ID: Task<Void, Never>] = [:]
    private var waveformPrefetchInflight: Set<URL> = []
    private var waveformPrefetchQueue: [URL] = []
    private var waveformPrefetchQueued: Set<URL> = []

    /// Wie viele Waveform-Prefetches gleichzeitig laufen dürfen. Jeder
    /// Prefetch öffnet einen AVAssetReader/AVAudioFile; ohne Limit sättigt
    /// der Scan eines Library-Ordners den MediaToolbox-Decoder-Pool und
    /// alle Worker bleiben in `copyNextSampleBuffer` auf einem internen
    /// Semaphor hängen.
    private static let maxConcurrentPrefetches = 3

    /// Hält den Security-Scoped Resource Access offen, solange die Library
    /// aktiv ist. Wird beim Wechsel/Schliessen freigegeben.
    private var accessingScopedURL: URL?

    init(
        repository: LibraryRepository,
        database: DatabaseService,
        waveformCache: WaveformCache
    ) {
        self.repository = repository
        self.database = database
        self.waveformCache = waveformCache
    }

    deinit {
        accessingScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// Tracks, deren Schreibvorgang abgelehnt wurde, weil die Datei im Player
    /// aktiv ist. Werden automatisch nachgeholt, sobald `setActiveTrack` auf
    /// eine andere URL wechselt.
    private var blockedByActivePlayer: Set<Track.ID> = []
    private var previousActiveURL: URL?

    /// Debounce-Fenster für Inline-Edits: spätestens danach landet das letzte
    /// Setzen auf der Platte. Kürzere Eingaben kollabieren in einen Schreibvorgang.
    private let saveDebounce: Duration = .milliseconds(600)

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose music folder")
        if panel.runModal() == .OK, let url = panel.url {
            persistAndScan(url)
        }
    }

    /// Verarbeitet eine per Drag & Drop hineingezogene Datei: stellt sicher,
    /// dass der Eltern-Ordner als Quelle bekannt ist (notfalls per
    /// `NSOpenPanel`, damit der Sandbox-Scope vom Nutzer freigegeben wird),
    /// schaltet die Sidebar auf diese Quelle und stösst einen Scan an.
    /// Liefert `true`, wenn die Datei nach Abschluss in der Liste auftauchen
    /// sollte; `false`, wenn der Nutzer den Picker abgebrochen hat.
    @discardableResult
    func handleDroppedFile(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let parentPath = parent.path

        // Bekannte Quelle? Dann ggf. nur umschalten — die Datei kommt durchs
        // Re-Scannen automatisch in die Liste.
        if let existing = folders.first(where: { $0.url == parentPath }) {
            if selectedFolderID != existing.id {
                Task { await selectFolder(id: existing.id) }
            }
            return true
        }

        // Unbekannte Quelle: Picker pre-positioned auf den Eltern-Ordner.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.title = String(localized: "Add folder as a source")
        panel.message = String(localized: "Grant access to this folder so its tracks can appear in the library.")
        panel.prompt = String(localized: "Add as source")
        if panel.runModal() == .OK, let folderURL = panel.url {
            persistAndScan(folderURL)
            return true
        }
        return false
    }

    /// Lädt die gespeicherten Ordner und scannt automatisch den zuletzt
    /// hinzugefügten. Wird in `ContentView.onAppear` ausgelöst.
    func restoreSavedFolders() {
        Task { [weak self, database] in
            let folders = (try? await database.listFolders()) ?? []
            await MainActor.run {
                guard let self else { return }
                self.folders = folders
            }
            if let last = folders.last {
                await self?.selectFolder(id: last.id)
            }
        }
    }

    /// Schaltet die aktive Quelle um: alter Scope wird freigegeben, das
    /// gespeicherte Bookmark des neuen Ordners wird resolved, dann gescannt.
    /// Bei verlorenem Sandbox-Zugriff (z. B. nach Reinstall/Signaturwechsel)
    /// bleibt der Eintrag erhalten und es wird ein Fehler signalisiert —
    /// nur wenn das Bookmark komplett unleserlich ist, wird gelöscht.
    @MainActor
    func selectFolder(id: String?) async {
        guard let id, let record = folders.first(where: { $0.id == id }) else {
            // Laufenden Scan stoppen, sonst pumpt der `for await`-Loop weiter
            // Tracks in die jetzt geleerte Liste — Tabelle würde nach dem
            // Clear sofort wieder voll laufen.
            scanTask?.cancel()
            scanTask = nil
            isScanning = false
            accessingScopedURL?.stopAccessingSecurityScopedResource()
            accessingScopedURL = nil
            selectedFolderID = nil
            tracks = []
            folderURL = nil
            lastLibraryError = nil
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: record.bookmark_data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                // TCC-Zugriff verloren (typisch nach App-Neuinstallation oder
                // Signaturwechsel). Pfad und Bookmark sind formal intakt,
                // aber das System verweigert den Scope. Eintrag behalten,
                // damit der Nutzer ihn gezielt entfernen und neu hinzufügen
                // kann.
                scanTask?.cancel()
                scanTask = nil
                isScanning = false
                accessingScopedURL?.stopAccessingSecurityScopedResource()
                accessingScopedURL = nil
                selectedFolderID = id
                tracks = []
                folderURL = nil
                lastLibraryError = String(
                    localized: "Access to ‘\(record.name)’ was lost. Remove the folder and add it again."
                )
                return
            }

            accessingScopedURL?.stopAccessingSecurityScopedResource()
            accessingScopedURL = url
            selectedFolderID = id
            lastLibraryError = nil
            scan(folder: url)

            if isStale,
               let refreshed = try? url.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                var updated = record
                updated.bookmark_data = refreshed
                Task { [database] in
                    try? await database.saveFolder(updated)
                }
            }
        } catch {
            // Bookmark komplett unleserlich → der Eintrag ist nicht mehr
            // reparierbar. Eintrag entfernen, aber dem Nutzer zeigen warum.
            lastLibraryError = String(
                localized: "Removed ‘\(record.name)’: bookmark unreadable (\(error.localizedDescription))."
            )
            try? await database.deleteFolder(id: id)
            folders.removeAll { $0.id == id }
            if selectedFolderID == id { selectedFolderID = nil; tracks = [] }
        }
    }

    /// Entfernt einen Ordner aus der Library. Datei-Inhalt bleibt
    /// unangetastet — nur das Bookmark wird vergessen.
    func removeFolder(id: String) {
        Task { [weak self, database] in
            try? await database.deleteFolder(id: id)
            await MainActor.run {
                guard let self else { return }
                self.folders.removeAll { $0.id == id }
                // Selektion neu setzen, wenn der aktive Ordner weg ist ODER
                // wenn selectedFolderID gar nicht (mehr) auf einen existierenden
                // Ordner zeigt. Letzteres deckt Desync-Fälle ab und sorgt vor
                // allem dafür, dass `tracks` zuverlässig geleert wird, wenn
                // der letzte Ordner verschwindet.
                let stillValid = self.folders.contains { $0.id == self.selectedFolderID }
                if !stillValid {
                    Task { await self.selectFolder(id: self.folders.last?.id) }
                }
            }
        }
    }

    /// Persistiert den vom Nutzer gewählten Ordner als FolderRecord mit
    /// Security-Scoped Bookmark, übernimmt den Scope und startet den Scan.
    private func persistAndScan(_ url: URL) {
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        accessingScopedURL?.stopAccessingSecurityScopedResource()
        accessingScopedURL = url
        if let bookmark {
            let record = FolderRecord(
                url: url,
                name: url.lastPathComponent,
                bookmarkData: bookmark
            )
            folders.append(record)
            selectedFolderID = record.id
            Task { [database] in
                try? await database.saveFolder(record)
            }
        }
        scan(folder: url)
    }

    func scan(folder: URL) {
        scanTask?.cancel()
        cancelPendingWaveformPrefetches()
        folderURL = folder
        tracks = []
        isScanning = true

        scanTask = Task { [folder, repository] in
            let (stream, _) = repository.scan(folder: folder)
            for await track in stream {
                if Task.isCancelled { break }
                tracks.append(track)
                // Welle direkt im Hintergrund rechnen lassen, sobald der Track
                // beim Scan auftaucht. WaveformCache dedupliziert per URL und
                // hält das Ergebnis sowohl im Speicher als auch in der DB —
                // ein späterer Klick auf den Track holt die Welle dann sofort
                // aus dem Cache statt synchron zu analysieren.
                prefetchWaveform(track)
            }
            isScanning = false
            // Tracks während des Scans landen unsortiert am Ende — am Schluss
            // einmal in die aktuelle Sortierung bringen. Danach bleibt die
            // Reihenfolge stabil, bis der User explizit re-sortiert.
            applySortOrder()
        }
    }

    var selectedTrack: Track? {
        guard let id = selectedTrackID else { return nil }
        return tracks.first(where: { $0.id == id })
    }

    // MARK: - Navigation

    /// Nächster Track in der aktuell angezeigten Sortierung. Wenn der gerade
    /// geladene Track nicht in der Library ist (z. B. via „Open file…"), wird
    /// auf den ersten Library-Track gesprungen, damit der Knopf trotzdem
    /// etwas Sinnvolles tut.
    func nextTrack(after url: URL?) -> Track? {
        guard !tracks.isEmpty else { return nil }
        guard let url, let idx = tracks.firstIndex(where: { $0.url == url }) else {
            return tracks.first
        }
        let next = idx + 1
        return next < tracks.count ? tracks[next] : nil
    }

    /// Vorheriger Track in der aktuell angezeigten Sortierung. Bei nicht-in-
    /// der-Library-geladenen Tracks Fallback auf den ersten Track.
    func previousTrack(before url: URL?) -> Track? {
        guard !tracks.isEmpty else { return nil }
        guard let url, let idx = tracks.firstIndex(where: { $0.url == url }) else {
            return tracks.first
        }
        let prev = idx - 1
        return prev >= 0 ? tracks[prev] : nil
    }

    /// Re-scannt die aktuell ausgewählte Quelle. Frisst extern hinzugefügte/
    /// entfernte Dateien ein und stellt die aktuelle Sortierung am Ende
    /// wieder her (siehe `scan` → `applySortOrder` nach Stream-Ende).
    func refresh() {
        guard let folderURL else { return }
        scan(folder: folderURL)
    }

    /// Setzt das Rating eines Tracks anhand seiner URL und plant den
    /// gewohnten Debounce-Save ein. Wird vom Player-Rating-Chip aufgerufen,
    /// damit dieselbe Persistenz-Pipeline läuft wie bei einer Inline-Edit
    /// in der Library-Tabelle.
    func setRating(forURL url: URL, _ rating: Rating) {
        guard let idx = tracks.firstIndex(where: { $0.url == url }) else { return }
        guard tracks[idx].rating != rating else { return }
        tracks[idx].rating = rating
        scheduleSave(tracks[idx])
    }

    // MARK: - Persistence

    /// Vom UI nach jeder Mutation aufrufen. Mehrere schnelle Aufrufe für
    /// denselben Track werden zu einem einzigen Schreibvorgang gebündelt.
    func scheduleSave(_ track: Track) {
        unsavedTrackIDs.insert(track.id)
        pendingSaves[track.id]?.cancel()
        let debounce = saveDebounce
        pendingSaves[track.id] = Task { [weak self, track] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self?.performSave(track)
        }
    }

    /// Manueller Speicher-Befehl (z. B. ⌘S oder Toolbar-Knopf): bricht das
    /// Debouncing ab und schreibt alle aktuell dirty Tracks sofort.
    func saveAllNow() {
        for (_, task) in pendingSaves { task.cancel() }
        pendingSaves.removeAll()
        let dirty = unsavedTrackIDs
        for id in dirty {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            Task { [weak self, track] in
                await self?.performSave(track)
            }
        }
    }

    private func performSave(_ track: Track) async {
        do {
            try await repository.save(track)
            unsavedTrackIDs.remove(track.id)
            blockedByActivePlayer.remove(track.id)
            lastWriteError = nil
        } catch let error as TagLibTrackStore.StoreError {
            if case .fileInUse = error {
                // Track ist gerade im Player aktiv: roten Punkt stehen
                // lassen, Schreiben wird beim Entladen automatisch nachgeholt.
                blockedByActivePlayer.insert(track.id)
            } else {
                lastWriteError = error.localizedDescription
            }
        } catch {
            lastWriteError = error.localizedDescription
        }
        pendingSaves.removeValue(forKey: track.id)
    }

    func setActiveTrack(_ url: URL?) {
        let previous = previousActiveURL
        previousActiveURL = url
        Task { [weak self, repository, previous, url] in
            await repository.setActiveTrack(url)
            await MainActor.run {
                guard let self else { return }
                if let previous, previous != url {
                    self.flushBlockedSaves(previousActiveURL: previous)
                }
            }
        }
    }

    /// Spielt zurückgestellte Schreibvorgänge ab, sobald der Player die Datei
    /// freigibt. Jedes ID-Match führt zu einem neuen `performSave` mit der
    /// aktuell im ViewModel hinterlegten Track-Version.
    private func flushBlockedSaves(previousActiveURL: URL) {
        let ids = blockedByActivePlayer.filter { id in
            tracks.first(where: { $0.id == id })?.url == previousActiveURL
        }
        for id in ids {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            blockedByActivePlayer.remove(id)
            Task { [weak self, track] in
                await self?.performSave(track)
            }
        }
    }

    // MARK: - Play-Count

    /// Inkrementiert den Play-Count des Tracks an `url` im DB-Cache und
    /// zieht den neuen Wert ins In-Memory-`tracks`-Array nach. Wird aus
    /// `ContentView.loadIntoPlayer` aufgerufen — also genau dann, wenn der
    /// Nutzer einen Track aus der Library in den Player lädt.
    func notePlay(forURL url: URL) {
        Task { [weak self, database] in
            guard let count = try? await database.incrementPlayCount(url: url) else { return }
            await MainActor.run {
                guard let self,
                      let idx = self.tracks.firstIndex(where: { $0.url == url })
                else { return }
                self.tracks[idx].playCount = count
            }
        }
    }

    /// Setzt die Play-Counts aller Tracks im aktuell ausgewählten Folder
    /// auf 0 (DB + In-Memory). Wird vom Toolbar-Knopf aufgerufen.
    func resetPlayCountsInCurrentFolder() {
        guard let folder = folderURL else { return }
        Task { [weak self, database] in
            try? await database.resetPlayCounts(inFolder: folder)
            await MainActor.run {
                guard let self else { return }
                for idx in self.tracks.indices {
                    self.tracks[idx].playCount = 0
                }
            }
        }
    }

    // MARK: - Analyse

    /// Startet eine Analyse für `track`, wenn BPM oder Key fehlen, und wärmt
    /// in jedem Fall den Waveform-Cache vor (auch wenn BPM+Key komplett sind),
    /// damit beim späteren Anklicken die Welle sofort da ist. Ein zweiter
    /// Aufruf während laufender Audio-Analyse wird ignoriert.
    func analyzeIfNeeded(_ track: Track) {
        prefetchWaveform(track)

        let needsBPM = track.bpm == nil
        let needsKey = track.key == nil
        guard needsBPM || needsKey else { return }
        if analysisState[track.id] == .scheduled { return }

        analysisState[track.id] = .scheduled
        let preset = bpmPreset
        let analyzer = analyzer
        let repository = repository

        Task { [weak self, track, needsBPM, needsKey, preset] in
            do {
                let result = try await analyzer.analyze(
                    url: track.url,
                    needsBPM: needsBPM,
                    needsKey: needsKey,
                    bpmRange: preset
                )
                await MainActor.run {
                    guard let self else { return }
                    guard let idx = self.tracks.firstIndex(where: { $0.id == track.id }) else {
                        self.analysisState[track.id] = .done
                        return
                    }
                    var updated = self.tracks[idx]
                    let gotBPM = result.bpm != nil
                    let gotKey = result.key != nil
                    if let bpm = result.bpm { updated.bpm = bpm }
                    if let key = result.key { updated.key = key }
                    self.tracks[idx] = updated
                    self.analysisState[track.id] = .done
                    if gotBPM || gotKey {
                        self.persistAfterAnalysis(updated)
                        self.onTrackAnalyzed?(updated)
                    }
                    if needsBPM && !gotBPM && needsKey && !gotKey {
                        self.lastAnalysisError = String(localized: "No BPM and no key detected: \(track.url.lastPathComponent)")
                    } else if needsBPM && !gotBPM {
                        self.lastAnalysisError = String(localized: "No BPM detected: \(track.url.lastPathComponent)")
                    } else if needsKey && !gotKey {
                        self.lastAnalysisError = String(localized: "No key detected: \(track.url.lastPathComponent)")
                    } else {
                        self.lastAnalysisError = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self?.analysisState[track.id] = .failed
                    self?.lastAnalysisError = error.localizedDescription
                }
            }
        }
    }

    /// Bulk-Trigger: stösst für jeden Track die Waveform-Vorberechnung an und
    /// — falls BPM oder Key fehlen — zusätzlich die Audio-Analyse. Der
    /// nil-Guard in `analyzeIfNeeded` sorgt dafür, dass die teure aubio/
    /// KeyFinder-Pipeline nur dort läuft, wo wirklich etwas fehlt.
    func analyzeAllMissing() {
        for track in tracks {
            analyzeIfNeeded(track)
        }
    }

    /// Verdoppelt bzw. halbiert den BPM-Wert manuell und persistiert die
    /// Änderung. Hilft bei einzelnen Tracks, bei denen aubio die Oktave
    /// daneben gegriffen hat (typisch: 71 statt 142, 87 statt 174).
    /// Tracks ohne BPM-Wert werden übersprungen.
    func scaleBPM(_ track: Track, factor: Double) {
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }),
              let current = tracks[idx].bpm,
              current > 0 else { return }
        let updated = (current * factor * 10).rounded() / 10
        tracks[idx].bpm = updated
        scheduleSave(tracks[idx])
        onTrackAnalyzed?(tracks[idx])
    }

    /// Erzwingt eine komplette Neuanalyse (BPM + Key) für `track` — auch wenn
    /// bereits Werte vorhanden sind. Wird vom Re-Analyze-Befehl in der Library
    /// verwendet, wenn man den Auto-Werten nicht traut.
    func reanalyze(_ track: Track) {
        prefetchWaveform(track)
        if analysisState[track.id] == .scheduled { return }

        analysisState[track.id] = .scheduled
        let preset = bpmPreset
        let analyzer = analyzer

        Task { [weak self, track, preset] in
            do {
                let result = try await analyzer.analyze(
                    url: track.url,
                    needsBPM: true,
                    needsKey: true,
                    bpmRange: preset
                )
                await MainActor.run {
                    guard let self else { return }
                    guard let idx = self.tracks.firstIndex(where: { $0.id == track.id }) else {
                        self.analysisState[track.id] = .done
                        return
                    }
                    var updated = self.tracks[idx]
                    let gotBPM = result.bpm != nil
                    let gotKey = result.key != nil
                    if let bpm = result.bpm { updated.bpm = bpm }
                    if let key = result.key { updated.key = key }
                    self.tracks[idx] = updated
                    self.analysisState[track.id] = .done
                    if gotBPM || gotKey {
                        self.persistAfterAnalysis(updated)
                        self.onTrackAnalyzed?(updated)
                    }
                    if !gotBPM && !gotKey {
                        self.lastAnalysisError = String(localized: "No BPM and no key detected: \(track.url.lastPathComponent)")
                    } else {
                        self.lastAnalysisError = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self?.analysisState[track.id] = .failed
                    self?.lastAnalysisError = error.localizedDescription
                }
            }
        }
    }

    /// Stellt sicher, dass die Waveform für `track` im Cache (Memory oder DB)
    /// liegt. Idempotent — pro URL läuft hoechstens ein Detached-Task. Ergebnis
    /// wird nicht verbraucht; `WaveformViewModel.setActiveURL` greift später
    /// auf dieselbe Cache-Instanz zu. Drosselt auf `maxConcurrentPrefetches`,
    /// überzählige Anfragen werden in einer FIFO-Queue abgearbeitet.
    private func prefetchWaveform(_ track: Track) {
        let url = track.url
        guard !waveformPrefetchInflight.contains(url),
              !waveformPrefetchQueued.contains(url) else { return }
        waveformPrefetchQueue.append(url)
        waveformPrefetchQueued.insert(url)
        pumpWaveformPrefetchQueue()
    }

    private func pumpWaveformPrefetchQueue() {
        while waveformPrefetchInflight.count < Self.maxConcurrentPrefetches,
              !waveformPrefetchQueue.isEmpty {
            let url = waveformPrefetchQueue.removeFirst()
            waveformPrefetchQueued.remove(url)
            waveformPrefetchInflight.insert(url)
            let cache = waveformCache
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await cache.waveform(for: url)
                await MainActor.run {
                    guard let self else { return }
                    self.waveformPrefetchInflight.remove(url)
                    self.pumpWaveformPrefetchQueue()
                }
            }
        }
    }

    /// Wirft die Prefetch-Queue weg (Inflight-Tasks laufen aus, ihre
    /// Ergebnisse landen einfach im Cache). Wird beim Folder-Wechsel
    /// aufgerufen, damit nicht weiter Wellen für die alte Quelle gerechnet
    /// werden.
    private func cancelPendingWaveformPrefetches() {
        waveformPrefetchQueue.removeAll()
        waveformPrefetchQueued.removeAll()
    }

    /// Analysisergebnisse landen direkt auf der Platte (ohne 600-ms-Debounce),
    /// damit Auto-Werte beim nächsten Programmstart vorhanden sind. Ist die
    /// Datei gerade im Player aktiv, lehnt der Store ab — `performSave`
    /// markiert sie dann für Nachschreiben beim nächsten Player-Wechsel.
    private func persistAfterAnalysis(_ track: Track) {
        unsavedTrackIDs.insert(track.id)
        pendingSaves[track.id]?.cancel()
        pendingSaves[track.id] = nil
        Task { [weak self, track] in
            await self?.performSave(track)
        }
    }
}
