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
        case title  = "Title"
        case artist = "Artist"
        case bpm    = "BPM"
        case key    = "Key"
        var id: String { rawValue }
    }

    /// Sort-Kriterium für die Anzeige. Persistiert über App-Sessions via
    /// UserDefaults; die View liest `sortedTracks` statt direkt `tracks`.
    var sortField: SortField = SortField(
        rawValue: UserDefaults.standard.string(forKey: "librarySortField") ?? ""
    ) ?? .title {
        didSet {
            UserDefaults.standard.set(sortField.rawValue, forKey: "librarySortField")
        }
    }

    /// Sortierte Trackliste fürs UI. Bei Gleichstand wird sekundär nach Titel
    /// sortiert, damit die Reihenfolge stabil bleibt.
    var sortedTracks: [Track] {
        tracks.sorted { a, b in
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

    var selectedFolder: FolderRecord? {
        guard let id = selectedFolderID else { return nil }
        return folders.first(where: { $0.id == id })
    }

    /// Lädt alle gespeicherten Quellen beim App-Start. Wenn welche vorhanden
    /// sind, wird die zuletzt hinzugefügte aktiv geschaltet — wie auf dem Mac.
    func restoreSavedFolders() async {
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
            lastError = "addFolder fehlgeschlagen (scope=\(didAccess)): \(error.localizedDescription)"
        }
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
                lastError = "Quelle kann nicht geöffnet werden."
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
    /// Player) in der Liste und schreibt ihn über das Repository zurück in
    /// Datei + DB-Cache. Schreibvorgänge auf den gerade abspielenden Track
    /// werden mit `.fileInUse` abgelehnt — die landen in `pendingSaves` und
    /// werden beim nächsten `setActiveTrack`-Wechsel automatisch nachgeholt.
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
                lastError = "Speichern fehlgeschlagen: \(storeError.localizedDescription)"
            }
        } catch {
            lastError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
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
            let result = try await analyzer.analyze(
                url: track.url,
                needsBPM: track.bpm == nil,
                needsKey: track.key == nil,
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
            try await repository.save(updated)
        } catch {
            lastError = "Analyse fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func scan(folder: URL) {
        scanTask?.cancel()
        isScanning = true
        let (stream, report) = repository.scan(folder: folder)
        scanTask = Task { [weak self] in
            for await track in stream {
                if Task.isCancelled { break }
                self?.tracks.append(track)
            }
            self?.isScanning = false
            // Wenn der Scan nichts gefunden hat, Diagnostik in lastError —
            // sonst rätselt der Nutzer, ob's am Picker, an iCloud, am
            // Filter oder am Pfad liegt.
            if self?.tracks.isEmpty == true {
                self?.lastError = "Scan-Diagnostik · \(report.summary)"
            }
        }
    }
}
