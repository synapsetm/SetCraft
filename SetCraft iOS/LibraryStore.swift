//
//  LibraryStore.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 03.06.2026.
//

import Foundation
import Observation
import SetCraftCore

/// iOS-Pendant zum Mac-`LibraryViewModel`. Bewusst schlank gehalten: kein
/// Inline-Edit, kein Drag&Drop, kein NSOpenPanel. Der DocumentPicker wird aus
/// der View via `.fileImporter` ausgelöst und ruft `addFolder(url:)`.
@Observable
@MainActor
final class LibraryStore {
    var folders: [FolderRecord] = []
    var selectedFolderID: String?
    var tracks: [Track] = []
    var isScanning = false
    var lastError: String?

    /// Tracks, deren aubio/KeyFinder-Analyse gerade läuft. Wird von der
    /// `TrackRowView` gelesen, um statt der BPM einen Spinner zu zeigen.
    var analyzing: Set<UUID> = []

    /// BPM-Bereichs-Heuristik (Verdoppeln/Halbieren). Default „universal".
    /// Auf iOS aktuell nicht in der UI änderbar — Mac-Toolbar-Preset wäre
    /// das Pendant, kommt ggf. später.
    var bpmPreset: BPMRangePreset = .universal

    enum SortField: String, CaseIterable, Identifiable {
        case title    = "Title"
        case artist   = "Artist"
        case bpm      = "BPM"
        case key      = "Key"
        case rating   = "Rating"
        case modified = "Modified"
        var id: String { rawValue }
    }

    /// Sort-Kriterium für die Anzeige. Persistiert über App-Sessions via
    /// UserDefaults. `tracks` selbst ist die Anzeige-Reihenfolge — Edits
    /// laufen in-place, ohne dass die Liste umsortiert wird. Re-Sort
    /// passiert nur, wenn der User explizit das Sort-Kriterium ändert
    /// (`didSet`), beim Pull-to-Refresh (siehe `refresh()`) oder am Ende
    /// eines Scans.
    var sortField: SortField = SortField(
        rawValue: UserDefaults.standard.string(forKey: "librarySortField") ?? ""
    ) ?? .title {
        didSet {
            UserDefaults.standard.set(sortField.rawValue, forKey: "librarySortField")
            applySortOrder()
        }
    }

    /// Re-sortiert `tracks` in-place nach `sortField`. Sekundärer Sort nach
    /// Titel hält die Reihenfolge bei Gleichstand stabil. Wird vom
    /// `sortField`-didSet, vom Pull-to-Refresh und am Ende eines Scans
    /// aufgerufen.
    func applySortOrder() {
        tracks.sort { a, b in
            switch sortField {
            case .title:
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case .artist:
                let cmp = a.artist.localizedCaseInsensitiveCompare(b.artist)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case .bpm:
                let av = a.bpm ?? .greatestFiniteMagnitude
                let bv = b.bpm ?? .greatestFiniteMagnitude
                if av != bv { return av < bv }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case .key:
                let av = Self.keyOrder(a.key)
                let bv = Self.keyOrder(b.key)
                if av != bv { return av < bv }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case .rating:
                // Absteigend: 5★ zuerst, ungerated (0★) zuletzt — DJ-Workflow
                // (Top-Tracks oben). Bei Gleichstand sekundär nach Titel.
                if a.rating.stars != b.rating.stars { return a.rating.stars > b.rating.stars }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case .modified:
                // Neueste zuerst — typischer DJ-Workflow (neu zugefügte Tracks
                // oben). nil-Werte landen ganz unten (distantPast).
                let av = a.modifiedDate ?? .distantPast
                let bv = b.modifiedDate ?? .distantPast
                if av != bv { return av > bv }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            }
        }
    }

    private static func keyOrder(_ key: CamelotKey?) -> Int {
        guard let key else { return .max }
        // 1A < 1B < 2A < 2B < ... < 12B
        return (key.number - 1) * 2 + (key.mode == .minor ? 0 : 1)
    }

    private let database: DatabaseService
    private let repository: LibraryRepository
    private let analyzer = AnalysisCoordinator()
    private var scanTask: Task<Void, Never>?
    private var accessingScopedURL: URL?
    /// `restoreSavedFolders` ist als `.task`-Aufruf aus der Library-View
    /// verdrahtet. SwiftUI-TabView feuert `.task` bei jedem Tab-Wechsel
    /// neu — ohne diesen Guard würde jedes Wechsel zurück zur Library-Tab
    /// einen kompletten Re-Scan auslösen (tracks = [] → neu füllen).
    private var didRestoreFolders = false
    /// Markiert, ob `lastError` aktuell die Scan-Diagnostik trägt — sonst
    /// können wir nicht über die lokalisierten Varianten hinweg sauber
    /// unterscheiden, welche Message vom Scan gesetzt wurde.
    private var scanDiagnosticActive = false

    /// Saves, die TagLibTrackStore mit `.fileInUse` abgelehnt hat — die Datei
    /// ist gerade im Player aktiv. Werden in `setActiveTrack` automatisch
    /// nachgeholt, sobald der Player auf einen anderen Track wechselt.
    private var pendingSaves: [UUID: Track] = [:]

    init(database: DatabaseService, repository: LibraryRepository) {
        self.database = database
        self.repository = repository
    }

    func isAnalyzing(trackID: UUID) -> Bool {
        analyzing.contains(trackID)
    }

    /// Stösst eine **vollständige** Re-Analyse (BPM + Key) für jeden
    /// geladenen Track an. Bewusst kein Skip-Wenn-Vorhanden-Guard: User
    /// hat sich aktiv für „alle analysieren" entschieden, und ohne echte
    /// Arbeit blitzen die Spinner nur für Mikrosekunden auf — wirkt
    /// wie ein Bug.
    func analyzeAll() {
        for track in tracks {
            let id = track.id
            Task { await analyze(trackID: id) }
        }
    }

    var selectedFolder: FolderRecord? {
        guard let id = selectedFolderID else { return nil }
        return folders.first(where: { $0.id == id })
    }

    // MARK: - Play-Count

    /// Inkrementiert den Play-Count des Tracks an `url` (DB + In-Memory).
    /// Wird vom `PlayerStore.load` bei jedem erfolgreichen Track-Load
    /// aufgerufen — analog zur Mac-`loadIntoPlayer`-Stelle.
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

    /// Setzt die Play-Counts aller Tracks des aktuell ausgewählten Folders
    /// auf 0. Aus dem ContentView-Source-Menü mit Bestätigungsdialog
    /// aufgerufen.
    func resetPlayCountsInCurrentFolder() async {
        guard let folderURL = selectedFolderURL else { return }
        try? await database.resetPlayCounts(inFolder: folderURL)
        for idx in tracks.indices {
            tracks[idx].playCount = 0
        }
    }

    /// URL des aktuell ausgewählten Folders über die Bookmark-Resolution
    /// des `accessingScopedURL`-Handles — der ist die einzige Stelle, an
    /// der die echte Filesystem-URL der Quelle vorliegt (FolderRecord.url
    /// ist nur ein Anzeige-Pfad-String).
    private var selectedFolderURL: URL? {
        accessingScopedURL
    }

    /// Lädt alle gespeicherten Quellen beim App-Start. Wenn welche vorhanden
    /// sind, wird die zuletzt hinzugefügte aktiv geschaltet — wie auf dem Mac.
    /// Idempotent: weitere Aufrufe (z. B. wenn SwiftUI das `.task` beim
    /// Tab-Wechsel neu feuert) sind ein No-op und triggern keinen Re-Scan.
    func restoreSavedFolders() async {
        guard !didRestoreFolders else { return }
        didRestoreFolders = true
        let saved = (try? await database.listFolders()) ?? []
        folders = saved
        if let last = saved.last {
            await selectFolder(id: last.id)
        }
    }

    /// Aus `.fileImporter` aufgerufen, nachdem der Nutzer einen Ordner gewählt
    /// hat (lokal, iCloud Drive oder ein in der Files-App gemountetes NAS).
    func addFolder(url: URL) async {
        // Auf iOS müssen wir den Security-Scope **vor** `bookmarkData` öffnen,
        // sonst wirft die iCloud-Drive-URL `NSURLBookmarkResolutionWithoutUIMask`
        // mit „Permission denied". DocumentPicker liefert die URL Security-Scoped,
        // aber inaktiv — wir aktivieren sie kurz, bookmarken, deaktivieren wieder.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            // iOS-Bookmarks aus dem DocumentPicker sind bereits Security-Scoped,
            // daher KEIN `.withSecurityScope` (macOS-only Flag).
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let record = FolderRecord(
                url: url,
                name: url.lastPathComponent,
                bookmarkData: bookmark
            )
            try await database.saveFolder(record)
            folders.append(record)
            await selectFolder(id: record.id)
        } catch {
            lastError = String(localized: "addFolder failed (scope=\(String(describing: didAccess))): \(error.localizedDescription)")
        }
    }

    /// Re-scannt die aktuell ausgewählte Quelle und wartet, bis der Stream
    /// durch ist. Wird vom Pull-to-Refresh in der Library-Liste aufgerufen,
    /// damit extern hinzugefügte/entfernte Dateien sichtbar werden.
    func refresh() async {
        guard let id = selectedFolderID else { return }
        await selectFolder(id: id)
        // selectFolder() startet einen neuen scanTask — auf dessen Ende
        // warten, damit der Pull-to-Refresh-Spinner nicht zu früh ausgeht.
        await scanTask?.value
    }

    /// Wechselt die aktive Quelle. Resolved das Bookmark, öffnet den Security-
    /// Scope, startet den Scan. Stale-Bookmarks werden refresht; unbrauchbare
    /// Einträge stillschweigend gelöscht (Ordner verschoben oder NAS getrennt).
    func selectFolder(id: String?) async {
        guard let id, let record = folders.first(where: { $0.id == id }) else {
            scanTask?.cancel()
            scanTask = nil
            isScanning = false
            accessingScopedURL?.stopAccessingSecurityScopedResource()
            accessingScopedURL = nil
            selectedFolderID = nil
            tracks = []
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: record.bookmark_data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                lastError = String(localized: "Source cannot be opened.")
                return
            }

            accessingScopedURL?.stopAccessingSecurityScopedResource()
            accessingScopedURL = url
            selectedFolderID = id
            tracks = []
            lastError = nil
            scan(folder: url)

            if isStale,
               let refreshed = try? url.bookmarkData(
                   options: [],
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                var updated = record
                updated.bookmark_data = refreshed
                try? await database.saveFolder(updated)
                if let index = folders.firstIndex(where: { $0.id == id }) {
                    folders[index] = updated
                }
            }
        } catch {
            try? await database.deleteFolder(id: id)
            folders.removeAll { $0.id == id }
            if selectedFolderID == id {
                selectedFolderID = nil
                tracks = []
            }
        }
    }

    /// Persistiert einen geänderten Track (Rating / BPM / Key Edits aus dem
    /// Player oder Library-Swipe) in der Liste und schreibt ihn über das
    /// Repository zurück in Datei + DB-Cache. Wird `.fileInUse` zurückgemeldet
    /// (Datei ist gerade im Player aktiv), wird der Save in `pendingSaves`
    /// geparkt — `setActiveTrack` drained ihn beim nächsten Player-Wechsel,
    /// `flushPendingSaves` beim App-Backgrounding (siehe scenePhase-Hook).
    func updateTrack(_ track: Track) async {
        if let idx = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[idx] = track
        }
        do {
            try await repository.save(track)
            pendingSaves.removeValue(forKey: track.id)
        } catch let storeError as TagLibTrackStore.StoreError {
            if case .fileInUse = storeError {
                pendingSaves[track.id] = track
            } else {
                lastError = String(localized: "Save failed: \(storeError.localizedDescription)")
            }
        } catch {
            lastError = String(localized: "Save failed: \(error.localizedDescription)")
        }
    }

    /// Schreibt alle bisher als `.fileInUse` abgelehnten Saves jetzt mit
    /// `force: true` raus — Notbremse für App-Backgrounding, damit der User
    /// keine Edits verliert, wenn iOS die App suspendiert oder beendet,
    /// bevor der Player auf einen anderen Track wechselt. `replaceItemAt`
    /// ist atomar; die noch offene `AVAudioFile`-fd zeigt anschließend
    /// aufs alte inode und spielt weiter ohne Glitch.
    func flushPendingSaves() async {
        let saves = Array(pendingSaves.values)
        pendingSaves.removeAll()
        for track in saves {
            try? await repository.save(track, force: true)
        }
    }

    /// Vom PlayerStore aufgerufen, wenn ein neuer Track in den Player
    /// geladen wird. Der TagLibTrackStore-Active-Guard schützt damit
    /// gleichzeitig vor parallelen Schreibvorgängen auf die noch im Player
    /// gehaltene Datei. Bei jedem Wechsel werden zuvor blockierte Saves
    /// (von Tracks, die jetzt nicht mehr aktiv sind) nachgeholt.
    func setActiveTrack(_ url: URL?) async {
        await repository.setActiveTrack(url)

        let drainable = pendingSaves.values.filter { $0.url != url }
        for track in drainable {
            pendingSaves.removeValue(forKey: track.id)
        }
        for track in drainable {
            try? await repository.save(track)
        }
    }

    /// Vergisst die Quelle. Dateien selbst bleiben unangetastet.
    func removeFolder(id: String) async {
        try? await database.deleteFolder(id: id)
        folders.removeAll { $0.id == id }
        if selectedFolderID == id {
            await selectFolder(id: folders.last?.id)
        }
    }

    /// Startet aubio + libKeyFinder für einen Track (nur die noch fehlenden
    /// Werte). Resultate werden in `tracks` und über `LibraryRepository.save`
    /// auch in der Datei + DB-Cache aktualisiert. Wird vom Swipe-Trailing-
    /// Analyze in der Track-Liste aufgerufen.
    func analyze(trackID: UUID) async {
        guard !analyzing.contains(trackID),
              let track = tracks.first(where: { $0.id == trackID })
        else { return }

        analyzing.insert(trackID)
        defer { analyzing.remove(trackID) }

        do {
            // User-getriggert (Swipe oder Menü) → IMMER vollständig analysieren,
            // auch wenn BPM/Key schon gesetzt sind. Re-Analyze ist genau dann
            // nützlich, wenn man den existierenden Werten misstraut.
            let result = try await analyzer.analyze(
                url: track.url,
                needsBPM: true,
                needsKey: true,
                bpmRange: bpmPreset
            )
            guard result.bpm != nil || result.key != nil else { return }

            var updated = track
            if let bpm = result.bpm { updated.bpm = bpm }
            if let key = result.key { updated.key = key }

            // Re-find: tracks-Array könnte sich zwischendurch verändert haben
            // (laufender Scan, andere Selektion).
            if let idx = tracks.firstIndex(where: { $0.id == trackID }) {
                tracks[idx] = updated
            }
            try await persistAnalyzed(updated)
        } catch {
            lastError = String(localized: "Analysis failed: \(error.localizedDescription)")
        }
    }

    /// Schreibt die analysierten BPM/Key-Werte in Datei + DB. Wenn die Datei
    /// gerade im Player aktiv ist, lehnt `TagLibTrackStore` mit `.fileInUse`
    /// ab — das ist kein Fehler, sondern Schutz vor parallelen Writes auf
    /// die offene `AVAudioFile`. Wir parken den Save dann in `pendingSaves`,
    /// `setActiveTrack` holt ihn beim nächsten Player-Wechsel nach.
    private func persistAnalyzed(_ track: Track) async throws {
        do {
            try await repository.save(track)
            pendingSaves.removeValue(forKey: track.id)
        } catch let storeError as TagLibTrackStore.StoreError {
            if case .fileInUse = storeError {
                pendingSaves[track.id] = track
            } else {
                throw storeError
            }
        }
    }

    private func scan(folder: URL) {
        scanTask?.cancel()
        isScanning = true
        scanDiagnosticActive = false
        let (stream, report) = repository.scan(folder: folder)
        scanTask = Task { [weak self] in
            for await track in stream {
                if Task.isCancelled { break }
                // Sobald der erste Track ankommt, eine evtl. von einer
                // vorherigen leeren Scan-Runde stehengebliebene Diagnostik
                // wegräumen — sonst klebt der rote Hinweis über einer
                // funktionierenden Liste.
                if self?.scanDiagnosticActive == true {
                    self?.lastError = nil
                    self?.scanDiagnosticActive = false
                }
                self?.tracks.append(track)
            }
            self?.isScanning = false
            // Tracks während des Scans landen unsortiert am Ende — am Schluss
            // einmal in die aktuelle Sortierung bringen. Danach bleibt die
            // Reihenfolge stabil, bis der User explizit re-sortiert oder
            // ein Refresh läuft.
            self?.applySortOrder()
            // Wenn der Scan nichts gefunden hat, Diagnostik in lastError —
            // sonst rätselt der Nutzer, ob's am Picker, an iCloud, am
            // Filter oder am Pfad liegt.
            if self?.tracks.isEmpty == true {
                self?.lastError = String(localized: "Scan diagnostics · \(report.summary)")
                self?.scanDiagnosticActive = true
            }
        }
    }
}
