import AppKit
import Foundation
import Observation
import SetCraftCore
import OSLog
import UniformTypeIdentifiers

private let playlistLog = Logger(subsystem: "ch.buehler.beat.SetCraft", category: "Playlist")

@Observable
final class LibraryViewModel {
    var tracks: [Track] = []
    /// Verzeichnis der aktiven Quelle — `nil`, wenn eine Einzeldatei-Quelle
    /// gewählt ist. Ordner-Aktionen (Import-Drop, Play-Count-Reset, Refresh
    /// über den Scanner) hängen daran.
    var folderURL: URL?
    /// Datei der aktiven Quelle — `nil` bei Ordner-Quellen. Genau eines von
    /// beiden ist gesetzt, sobald eine Quelle ausgewählt ist.
    var fileURL: URL?

    /// M3U der aktiven Quelle — `nil`, wenn keine Playlist gewählt ist.
    var playlistURL: URL?

    /// Pfad der aktiven Quelle, egal welcher Art — für Anzeige und für die
    /// Frage, ob überhaupt etwas ausgewählt ist.
    var sourceURL: URL? { folderURL ?? fileURL ?? playlistURL }

    var isPlaylistSource: Bool { playlistURL != nil }

    /// Eintrag und Auflösungsstatus jeder Zeile der aktiven Playlist, über
    /// `Track.id`. Leer bei Ordner- und Datei-Quellen.
    private(set) var playlistRows: [Track.ID: PlaylistRow] = [:]

    struct PlaylistRow {
        var entry: PlaylistEntry
        var status: PlaylistEntryStatus
    }

    /// Playlists, für die in dieser Sitzung schon um Freigabe gebeten wurde —
    /// der Dialog kommt genau einmal, nicht bei jedem Auswählen.
    private var accessPromptedPlaylists: Set<String> = []
    var isScanning = false
    /// Mehrfachselektion: `Table` braucht ein `Set<Track.ID>` als Binding,
    /// damit Shift-/Cmd-Klick und Drag-Bulkaktionen funktionieren. Einzel-
    /// Track-Operationen (Re-Analyze, Player laden) greifen weiter auf
    /// `selectedTrack` — das liefert den ersten Eintrag der Selektion.
    var selectedTrackIDs: Set<Track.ID> = []
    var lastWriteError: String?
    var lastAnalysisError: String?
    var lastLibraryError: String?

    /// Liste aller persistierten Quellen (Ordner). Wird beim App-Start
    /// aus der DB geladen.
    var folders: [FolderRecord] = []

    /// ID des aktuell angezeigten Ordners. Schaltet beim Wechsel den
    /// `tracks`-Inhalt um. Wird bei jeder Änderung mitgeschrieben, damit der
    /// nächste App-Start wieder dieselbe Quelle öffnet (siehe
    /// `restoreSavedFolders`).
    var selectedFolderID: String? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            LastSelectedSource.id = selectedFolderID
        }
    }

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

    /// Wiedergabezustand für die Anzeige klingender Tonarten. Wird vom
    /// `ContentView` aus dem `TransportViewModel` gespiegelt. Reiner
    /// Anzeige-Zustand — er beeinflusst nie, was in die Datei geschrieben
    /// wird (siehe Pflichtregel in `CLAUDE.md`).
    var soundingContext: SoundingContext = .none {
        didSet {
            guard soundingContext != oldValue, isSortingByKey else { return }
            applySortOrder()
        }
    }

    /// `true`, wenn aktuell nach der Key-Spalte sortiert wird.
    private var isSortingByKey: Bool {
        sortOrder.first?.keyPath == \Track.keySortable
    }

    /// Re-sortiert `tracks` in-place mit der aktuellen `sortOrder`. Wird
    /// vom Refresh-Button, beim Wechsel der Sortierspalte und am Ende
    /// eines Scans aufgerufen.
    ///
    /// Sonderfall Key-Spalte: ist ein Master-Tempo gesetzt, sind die Tonarten
    /// verschoben und es wird nach dem **klingenden** Key sortiert.
    /// `KeyPathComparator` kann das nicht abbilden, weil der Wert vom
    /// Wiedergabezustand abhängt und nicht am `Track` hängt.
    func applySortOrder() {
        guard isSortingByKey, soundingContext.isActive,
              let order = sortOrder.first?.order
        else {
            tracks.sort(using: sortOrder)
            return
        }
        let context = soundingContext
        tracks.sort { lhs, rhs in
            let l = lhs.keySortValue(in: context)
            let r = rhs.keySortValue(in: context)
            if l != r {
                return order == .forward ? l < r : l > r
            }
            // Gleicher klingender Key → stabile Zweitsortierung nach Titel,
            // damit die Liste bei Tempoänderungen nicht zufällig umspringt.
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// IDs der Tracks mit Änderungen, die noch nicht auf der Platte sind.
    /// Erst nach erfolgreichem `save` wird die ID hier wieder entfernt.
    var unsavedTrackIDs: Set<Track.ID> = []

    var hasUnsavedChanges: Bool { !unsavedTrackIDs.isEmpty }

    /// URLs, deren Analyse gerade läuft oder eingeplant ist.
    ///
    /// Bewusst über die URL statt über `Track.id`: die ID wird bei jedem Scan
    /// neu vergeben. Über die ID würde ein Wechsel weg und wieder zurück
    /// dieselbe Datei ein zweites Mal in die Queue stellen, und die Spinner in
    /// der Tabelle blieben aus, weil die neu gescannte Zeile die alte ID nicht
    /// kennt.
    private(set) var analysesInFlight: Set<URL> = []

    /// Läuft für diesen Track gerade eine Analyse? Steuert die Spinner in der
    /// BPM- und der Key-Spalte.
    func isAnalyzing(_ track: Track) -> Bool {
        analysesInFlight.contains(track.url)
    }

    /// Wahl des erwarteten BPM-Bereichs für die Oktav-Korrektur.
    var bpmPreset: BPMRangePreset = .universal

    var pendingAnalysisCount: Int { analysesInFlight.count }

    /// Wie viele Tracks des **aktuellen Ordners** der Analyse noch offenstehen
    /// — die Zahl hinter „Analyze missing". Zwei Ausnahmen:
    ///
    /// - DJ-Mixes zählen nicht mit; sie werden bewusst übersprungen, also darf
    ///   der Knopf sie auch nicht versprechen.
    /// - Bereits eingeplante Tracks zählen nicht mit. Sonst stünde nach dem
    ///   Klick weiter dieselbe Zahl da, obwohl alles schon läuft, und der
    ///   Knopf lüde zum wirkungslosen Nachklicken ein. Wie viel gerade
    ///   gerechnet wird, sagt `pendingAnalysisCount` in der Statuszeile.
    /// - Bezieht sich wie `analyzeAllMissing` auf die gefilterte Liste.
    var missingAnalysisCount: Int {
        let inFlight = analysesInFlight
        return visibleTracks.lazy.filter {
            !self.isUnavailable($0)
                && !$0.isLikelyDJMix
                && ($0.bpm == nil || $0.key == nil)
                && !inFlight.contains($0.url)
        }.count
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
    private var restoreTask: Task<Void, Never>?
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

    /// Hält den Security-Scoped Zugriff auf die aktive Quelle offen und zählt
    /// die laufenden Zugriffe mit. Beim Quellenwechsel wird der alte Scope nur
    /// abgemeldet — geschlossen wird er erst, wenn die letzte noch laufende
    /// Analyse bzw. der letzte Tag-Write sein Token zurückgibt. Ohne diese
    /// Zählung verliert ein Schreibvorgang mitten in der Operation den
    /// Dateizugriff (EPERM beim Rename, siehe `SecurityScope`).
    private let scopes = SecurityScopeRegistry()

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
        scopes.releaseAll()
    }

    /// Tracks, deren Schreibvorgang abgelehnt wurde, weil die Datei im Player
    /// aktiv ist. Werden automatisch nachgeholt, sobald `setActiveTrack` auf
    /// eine andere URL wechselt.
    private var blockedByActivePlayer: Set<Track.ID> = []
    private var previousActiveURL: URL?

    /// Geparkte Schreibvorgänge für Dateien, die gerade im Player laufen —
    /// über die URL gehalten, weil die Scan-ID nach einem Quellenwechsel
    /// nicht mehr in `tracks` steht. Zwei Herkünfte:
    /// - Analyse-Ergebnisse für Tracks, die schon beim Ergebnis nicht mehr
    ///   in der Liste standen (`persistOrphanedAnalysis`),
    /// - Edits aus `performSave`, die am Player-Guard hängen blieben. Ohne
    ///   diese Kopie ging ein Rating auf den spielenden Track verloren, wenn
    ///   der Nutzer danach die Quelle wechselte (2026-11-21).
    ///
    /// Das Token hält den Scope der Quelle offen, bis geschrieben ist —
    /// sonst wäre er nach dem Wechsel womöglich schon zu.
    private var orphanedSaves: [URL: ParkedSave] = [:]

    private struct ParkedSave {
        var track: Track
        var token: SecurityScope.Token?
    }

    private func park(_ track: Track) {
        let url = track.url
        // Bestehendes Token weiterverwenden: ein frisches liefert `nil`,
        // wenn die Quelle inzwischen gewechselt hat.
        let token = orphanedSaves[url]?.token ?? scopes.token(for: url)
        orphanedSaves[url] = ParkedSave(track: track, token: token)
    }

    /// Frisch geladene Zeile mit dem Stand eines geparkten Writes für dieselbe
    /// Datei. Ohne das zeigte ein Wechsel weg und zurück das alte Rating: der
    /// Write wartet noch auf den Player, Cache und Datei kennen den neuen
    /// Wert also nicht (2026-11-21). Der geparkte Write wird auf die neue
    /// Zeile umgehängt, damit ihr «ungespeichert»-Punkt nach dem Schreiben
    /// verschwindet.
    private func adoptParked(_ loaded: Track) -> Track {
        guard let parked = orphanedSaves[loaded.url] else { return loaded }
        let merged = parked.track.reassigned(to: loaded)
        unsavedTrackIDs.remove(parked.track.id)
        blockedByActivePlayer.remove(parked.track.id)
        unsavedTrackIDs.insert(merged.id)
        orphanedSaves[loaded.url] = ParkedSave(track: merged, token: parked.token)
        return merged
    }

    /// Entfernt die geparkte Kopie, wenn sie zu genau diesem Track gehört —
    /// ein Analyse-Ergebnis für dieselbe Datei (andere ID) bleibt stehen.
    private func unpark(_ track: Track) {
        guard let parked = orphanedSaves[track.url], parked.track.id == track.id else { return }
        parked.token?.release()
        orphanedSaves.removeValue(forKey: track.url)
    }

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

    // MARK: - Playlist-Quellen (M3U)

    /// `true` für Playlist-Zeilen ohne ladbare Datei (fehlt, kein Zugriff,
    /// mehrdeutig, Netz-Eintrag). Auf solche Zeilen wird nie geschrieben,
    /// sie werden weder analysiert noch gespielt.
    func isUnavailable(_ track: Track) -> Bool {
        guard let row = playlistRows[track.id] else { return false }
        return row.status.fileURL == nil
    }

    func playlistStatus(for track: Track) -> PlaylistEntryStatus? {
        playlistRows[track.id]?.status
    }

    /// Pfadzeile aus der M3U, für den Tooltip fehlender Einträge.
    func playlistEntryLine(for track: Track) -> String? {
        playlistRows[track.id]?.entry.rawLine
    }

    /// Zahlen für die Statuszeile: fehlende Einträge (inkl. mehrdeutiger und
    /// Netz-Einträge) und Einträge ohne Zugriff.
    var playlistMissingCount: Int {
        playlistRows.values.lazy.filter {
            switch $0.status {
            case .missing, .ambiguous, .unsupported: return true
            default: return false
            }
        }.count
    }

    var playlistNoAccessCount: Int {
        playlistRows.values.lazy.filter {
            if case .noAccess = $0.status { return true }
            return false
        }.count
    }

    /// Räumt den Playlist-Zustand ab, wenn eine Ordner- oder Datei-Quelle
    /// geladen wird. Steht die Sortierung noch auf «#», zurück auf Titel —
    /// ausserhalb einer Playlist hat die Spalte keine Werte.
    private func leavePlaylist() {
        playlistURL = nil
        playlistRows = [:]
        if sortOrder.first?.keyPath == \Track.playlistIndexSortable {
            sortOrder = [KeyPathComparator(\Track.title, order: .forward)]
        }
    }

    /// Steht dieselbe Datei mehrfach in der Playlist, bekommen alle Zeilen
    /// den neuen Stand. Sonst schriebe ein späterer Edit an einer veralteten
    /// Zeile zum Beispiel das alte Rating zurück in die Datei.
    private func mirrorToDuplicates(_ track: Track) {
        guard isPlaylistSource else { return }
        for i in tracks.indices where tracks[i].url == track.url && tracks[i].id != track.id {
            guard !isUnavailable(tracks[i]) else { continue }
            tracks[i] = track.reassigned(to: tracks[i])
        }
    }

    func choosePlaylist() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.m3uPlaylist]
            + ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.title = String(localized: "Import playlist")
        if panel.runModal() == .OK, let url = panel.url {
            importPlaylist(url)
        }
    }

    /// Nimmt die M3U als Quelle auf. Ist sie schon da, wird nur umgeschaltet.
    /// Das Bookmark auf die Datei reicht, um sie nach einem Neustart wieder zu
    /// lesen; die Musik selbst kommt über die Ordnerquellen.
    private func importPlaylist(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = folders.first(where: { $0.kind == .playlist && $0.url == path }) {
            Task { await selectFolder(id: existing.id) }
            return
        }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            lastLibraryError = String(localized: "Could not add ‘\(url.lastPathComponent)’ to the library.")
            return
        }
        let record = FolderRecord(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            bookmarkData: bookmark,
            kind: .playlist
        )
        folders.append(record)
        Task { [database] in
            try? await database.saveFolder(record)
        }
        // Panel-URLs sind ohne Scope zugreifbar — siehe `persistFileSource`.
        scopes.activate(url, requireScope: false)
        selectedFolderID = record.id
        lastLibraryError = nil
        loadPlaylist(id: record.id, url: url)
    }

    /// Liest die Playlist, löst die Einträge auf und füllt `tracks` in
    /// Playlist-Reihenfolge. Der Scope der M3U ist zu diesem Zeitpunkt
    /// bereits aktiv; die Ordnerquellen kommen als Begleit-Scopes dazu.
    ///
    /// Zwei Durchläufe: der erste mit den Pfaden aus dem Track-Cache als
    /// Relink-Kandidaten (billig), der zweite nur, wenn danach noch etwas
    /// fehlt — dann mit dem Listing aller Ordnerquellen, das auf einem NAS
    /// Sekunden kosten kann.
    func loadPlaylist(id: String, url: URL) {
        scanTask?.cancel()
        cancelPendingWaveformPrefetches()
        let previouslySelected = Set(
            tracks.filter { selectedTrackIDs.contains($0.id) }.map(\.url.standardizedFileURL)
        )
        let wasSamePlaylist = playlistURL == url
        folderURL = nil
        fileURL = nil
        playlistURL = url
        playlistRows = [:]
        tracks = []
        isScanning = true
        if !wasSamePlaylist {
            sortOrder = [KeyPathComparator(\Track.playlistIndexSortable, order: .forward)]
        }

        scopes.retireCompanions()
        let sources = folders.filter { $0.kind != .playlist }
        scanTask = Task { [weak self, database, repository] in
            let bookmarkURLs = await PlaylistResolver.resolveBookmarks(sources.map(\.bookmark_data))
            guard let self, !Task.isCancelled else { return }
            // `/Volumes/` ist per Entitlement freigegeben (siehe
            // `SetCraft.entitlements`) — Tracks auf NAS und USB brauchen
            // keinen Ordner-Dialog. Nur für Pfade ausserhalb bleibt er.
            var roots: [URL] = [Self.volumesRoot]
            var folderRoots: [URL] = []
            for (record, resolved) in zip(sources, bookmarkURLs) {
                guard let resolved, self.scopes.addCompanion(resolved) else { continue }
                roots.append(resolved)
                if record.kind == .folder { folderRoots.append(resolved) }
            }

            let links = (try? await database.playlistLinks(playlistID: id)) ?? [:]
            let cachedPaths = (try? await database.cachedTrackPaths()) ?? []
            let cachedFiles = cachedPaths.map { URL(fileURLWithPath: $0) }
            var context = PlaylistResolver.Context(
                grantedRoots: roots,
                relinkIndex: RelinkIndex(files: cachedFiles),
                storedLinks: links
            )

            var resolved: [ResolvedPlaylistEntry]
            do {
                resolved = try await PlaylistResolver.load(playlistAt: url, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                self.lastLibraryError = String(
                    localized: "Could not read playlist ‘\(url.lastPathComponent)’: \(error.localizedDescription)"
                )
                self.isScanning = false
                return
            }

            let stillOpen = resolved.contains {
                switch $0.status {
                case .missing, .ambiguous: return true
                default: return false
                }
            }
            if stillOpen, !folderRoots.isEmpty, !Task.isCancelled {
                let listed = await PlaylistResolver.collectAudioFiles(in: folderRoots)
                context.relinkIndex = RelinkIndex(files: cachedFiles + listed)
                resolved = await PlaylistResolver.resolve(resolved.map(\.entry), context: context)
            }

            // Verteilung ins Log: daran lässt sich ablesen, ob die Sandbox für
            // Pfade ausserhalb der Quellen EPERM (→ noAccess) oder ENOENT
            // (→ missing) meldet.
            let summary = Dictionary(grouping: resolved, by: { Self.statusName($0.status) })
                .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
            playlistLog.notice("Loaded \(url.lastPathComponent, privacy: .public): \(summary, privacy: .public), roots=\(roots.count)")

            for item in resolved {
                if Task.isCancelled { break }
                var track: Track
                if let file = item.status.fileURL {
                    track = await repository.loadTrack(url: file) ?? Self.placeholderTrack(for: item.entry, url: file)
                } else {
                    track = Self.placeholderTrack(for: item.entry, url: nil)
                }
                if Task.isCancelled { break }
                track.playlistIndex = item.entry.index
                track = self.adoptParked(track)
                self.playlistRows[track.id] = PlaylistRow(entry: item.entry, status: item.status)
                self.tracks.append(track)
                self.prefetchWaveform(track)
            }
            guard !Task.isCancelled else { return }
            self.isScanning = false
            self.applySortOrder()
            if !previouslySelected.isEmpty {
                self.selectedTrackIDs = Set(
                    self.tracks.filter { previouslySelected.contains($0.url.standardizedFileURL) }.map(\.id)
                )
            }
            self.requestAccessIfNeeded(playlistID: id, resolved: resolved)
        }
    }

    /// Per Sandbox-Ausnahme freigegeben, siehe `SetCraft.entitlements`.
    private static let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    private static func statusName(_ status: PlaylistEntryStatus) -> String {
        switch status {
        case .resolved:    return "resolved"
        case .relinked:    return "relinked"
        case .noAccess:    return "noAccess"
        case .ambiguous:   return "ambiguous"
        case .missing:     return "missing"
        case .unsupported: return "unsupported"
        }
    }

    /// Zeile für einen Eintrag ohne lesbaren Tag: Artist und Titel aus
    /// `#EXTINF`, sonst der Dateiname.
    private static func placeholderTrack(for entry: PlaylistEntry, url: URL?) -> Track {
        let fallbackURL: URL
        switch entry.location {
        case .local(let local):     fallbackURL = local
        case .foreign(let path):    fallbackURL = URL(fileURLWithPath: path)
        case .remote(let remote):   fallbackURL = remote
        }
        let target = url ?? fallbackURL
        return Track(
            url: target,
            title: entry.extTitle ?? target.deletingPathExtension().lastPathComponent,
            artist: entry.extArtist ?? "",
            durationSeconds: TimeInterval(entry.extDuration ?? 0)
        )
    }

    /// Bittet einmal pro Sitzung und Playlist um Zugriff auf den kleinsten
    /// Ordner, der alle Einträge ohne Zugriff enthält. Die Freigabe wird wie
    /// «Add folder…» als Ordnerquelle gespeichert, danach wird neu aufgelöst.
    private func requestAccessIfNeeded(playlistID: String, resolved: [ResolvedPlaylistEntry]) {
        guard resolved.contains(where: { if case .noAccess = $0.status { return true }; return false }),
              !accessPromptedPlaylists.contains(playlistID)
        else { return }
        accessPromptedPlaylists.insert(playlistID)
        requestPlaylistAccess()
    }

    /// Fragt nach Zugriff auf die Tracks der aktiven Playlist, die ausserhalb
    /// der Quellen liegen. Automatisch einmal nach dem Laden, danach über den
    /// Knopf in der Statuszeile — wer den Dialog abgelehnt hat, braucht einen
    /// Weg zurück, ohne die App neu zu starten.
    ///
    /// Die Freigabe wird wie «Add folder…» als Ordnerquelle gespeichert. Neu
    /// aufgelöst werden danach nur die Zeilen ohne Datei, an Ort und Stelle —
    /// Auswahl, Scrollposition und laufende Wiedergabe bleiben unberührt.
    func requestPlaylistAccess() {
        let denied = tracks.compactMap { track -> URL? in
            if case .noAccess(let url) = playlistRows[track.id]?.status { return url }
            return nil
        }
        guard !denied.isEmpty,
              let playlistID = selectedFolderID,
              let record = folders.first(where: { $0.id == playlistID && $0.kind == .playlist })
        else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = PlaylistResolver.commonAncestor(of: denied)
        panel.message = String(
            localized: "“\(record.name)” contains \(denied.count) tracks outside your sources. Allow access to their folder so SetCraft can load them."
        )
        panel.prompt = String(localized: "Allow Access")
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        if !folders.contains(where: { $0.kind == .folder && $0.url == folder.standardizedFileURL.path }),
           let bookmark = try? folder.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            let source = FolderRecord(url: folder, name: folder.lastPathComponent, bookmarkData: bookmark)
            folders.append(source)
            Task { [database] in
                try? await database.saveFolder(source)
            }
        }
        // Panel-URLs sind ohne Scope zugreifbar. Beim nächsten vollen Laden
        // kommt der Ordner regulär über sein Bookmark dazu.
        scopes.addCompanion(folder, requireScope: false)
        resolveUnavailableRows(playlistID: playlistID, newFolder: folder)
    }

    /// Löst nur die Zeilen ohne Datei erneut auf und ersetzt sie in `tracks`
    /// an derselben Stelle und mit derselben ID. Der freigegebene Ordner
    /// dient zusätzlich als Relink-Kandidat für Einträge, die vorher fehlten.
    private func resolveUnavailableRows(playlistID: String, newFolder: URL) {
        let pending = tracks.compactMap { track -> (Track.ID, PlaylistEntry)? in
            guard let row = playlistRows[track.id], row.status.fileURL == nil else { return nil }
            return (track.id, row.entry)
        }
        guard !pending.isEmpty else { return }
        let roots = scopes.openURLs

        Task { [weak self, repository] in
            let listed = await PlaylistResolver.collectAudioFiles(in: [newFolder])
            let context = PlaylistResolver.Context(grantedRoots: roots, relinkIndex: RelinkIndex(files: listed))
            let resolved = await PlaylistResolver.resolve(pending.map(\.1), context: context)

            for ((id, _), item) in zip(pending, resolved) {
                guard let file = item.status.fileURL else { continue }
                let loaded = await repository.loadTrack(url: file)
                // Quelle gewechselt, während geladen wurde → nichts mehr anfassen.
                guard let self, self.selectedFolderID == playlistID,
                      let idx = self.tracks.firstIndex(where: { $0.id == id })
                else { return }
                let fresh = loaded ?? Track(url: file, title: self.tracks[idx].title,
                                            artist: self.tracks[idx].artist,
                                            durationSeconds: self.tracks[idx].durationSeconds)
                self.tracks[idx] = self.adoptParked(fresh.reassigned(to: self.tracks[idx]))
                self.playlistRows[id] = PlaylistRow(entry: item.entry, status: item.status)
                self.prefetchWaveform(self.tracks[idx])
            }
            playlistLog.notice("Access granted for \(newFolder.lastPathComponent, privacy: .public): \(resolved.filter { $0.status.fileURL != nil }.count, privacy: .public) of \(pending.count, privacy: .public) rows now loadable")
        }
    }

    // MARK: - Externes Öffnen (Finder / Standard-Player / Drop)

    /// Verarbeitet eine Datei, die von aussen hereingereicht wurde (Finder-
    /// Doppelklick, wenn SetCraft Standard-Player ist, „Öffnen mit", Drag &
    /// Drop). Stellt sicher, dass der Track in der Library sichtbar ist, und
    /// liefert ihn zurück — damit der Aufrufer Selektion, Analyse und
    /// Player-Baseline nachziehen kann.
    ///
    /// Deckt bereits eine Quelle die Datei ab, wird nur dorthin umgeschaltet.
    /// Sonst wird **genau dieser Track** als eigene Quelle aufgenommen — ohne
    /// Rückfrage und ohne sein Verzeichnis mitzunehmen.
    @MainActor
    @discardableResult
    func handleExternallyOpenedFile(_ url: URL) async -> Track? {
        // Beim Kaltstart kann das Open-Event vor `ContentView.onAppear`
        // eintreffen. Erst die gespeicherten Quellen laden — sonst hielten
        // wir eine längst bekannte Datei für neu und legten sie doppelt an.
        restoreSavedFolders()
        await restoreTask?.value

        let file = url.standardizedFileURL

        if let existing = source(covering: file) {
            if selectedFolderID != existing.id {
                await selectFolder(id: existing.id)
            }
        } else {
            guard persistFileSource(file) else { return nil }
        }

        let track = await trackAfterScan(url: file)
        // Ein aktiver Filter darf den Track nicht verstecken — der Aufrufer
        // wählt ihn gleich aus, und eine unsichtbare Auswahl wäre gefährlich.
        if let track, isFiltering, !visibleTracks.contains(where: { $0.id == track.id }) {
            filterText = ""
        }
        return track
    }

    /// Erste Quelle, die `file` bereits abdeckt: entweder die Datei selbst als
    /// Einzel-Quelle oder **genau** ihr Eltern-Ordner. Vorfahren weiter oben
    /// zählen nicht — der Scan ist flach, dort würde die Datei nicht auftauchen.
    private func source(covering file: URL) -> FolderRecord? {
        let parentPath = file.deletingLastPathComponent().path
        return folders.first { record in
            switch record.kind {
            case .file:     return record.url == file.path
            case .folder:   return record.url == parentPath
            case .playlist: return false
            }
        }
    }

    /// Nimmt eine einzelne Datei als Quelle auf. Der Sandbox-Zugriff auf eine
    /// von aussen gereichte Datei reicht aus, um ein Security-Scoped Bookmark
    /// darauf zu erzeugen — damit überlebt der Eintrag den Neustart, ganz ohne
    /// Dialog. (Für das *Verzeichnis* wäre eine explizite Freigabe nötig —
    /// genau deshalb wird hier nur der Track selbst aufgenommen.)
    @discardableResult
    private func persistFileSource(_ url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            lastLibraryError = String(
                localized: "Could not add ‘\(url.lastPathComponent)’ to the library."
            )
            return false
        }

        let record = FolderRecord(
            url: url,
            name: url.lastPathComponent,
            bookmarkData: bookmark,
            kind: .file
        )
        folders.append(record)
        Task { [database] in
            try? await database.saveFolder(record)
        }

        // Panel-URLs sind nicht security-scoped — sie bleiben auch ohne
        // Scope zugreifbar, deshalb `requireScope: false`.
        scopes.activate(url, requireScope: false)
        selectedFolderID = record.id
        lastLibraryError = nil
        scan(file: url)
        return true
    }

    /// Wartet auf den laufenden Scan und sucht die Datei in der Liste. Wird sie
    /// nicht gefunden, ist sie vermutlich nach dem letzten Scan dazugekommen —
    /// dann einmal frisch scannen und erneut nachsehen.
    @MainActor
    private func trackAfterScan(url: URL) async -> Track? {
        await scanTask?.value
        if let hit = tracks.first(where: { $0.url.standardizedFileURL == url }) { return hit }

        refresh()
        await scanTask?.value
        return tracks.first(where: { $0.url.standardizedFileURL == url })
    }

    /// Lädt die gespeicherten Ordner und scannt automatisch die zuletzt
    /// benutzte Quelle; ist die nicht mehr da, die zuletzt hinzugefügte
    /// (`LastSelectedSource.resolve`). Wird in `ContentView.onAppear`
    /// ausgelöst — und von
    /// `handleExternallyOpenedFile`, falls das Open-Event zuerst kommt.
    /// Idempotent: der zweite Aufruf hängt sich an den laufenden Task.
    @MainActor
    func restoreSavedFolders() {
        guard restoreTask == nil else { return }
        restoreTask = Task { [weak self, database] in
            let folders = (try? await database.listFolders()) ?? []
            await MainActor.run {
                guard let self else { return }
                self.folders = folders
            }
            if let target = LastSelectedSource.resolve(in: folders) {
                await self?.selectFolder(id: target.id)
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
            scopes.deactivate()
            selectedFolderID = nil
            tracks = []
            folderURL = nil
            fileURL = nil
            playlistURL = nil
            playlistRows = [:]
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
            guard scopes.activate(url) else {
                // TCC-Zugriff verloren (typisch nach App-Neuinstallation oder
                // Signaturwechsel). Pfad und Bookmark sind formal intakt,
                // aber das System verweigert den Scope. Eintrag behalten,
                // damit der Nutzer ihn gezielt entfernen und neu hinzufügen
                // kann.
                scanTask?.cancel()
                scanTask = nil
                isScanning = false
                scopes.deactivate()
                selectedFolderID = id
                tracks = []
                folderURL = nil
                fileURL = nil
                playlistURL = nil
                playlistRows = [:]
                lastLibraryError = String(
                    localized: "Access to ‘\(record.name)’ was lost. Remove the folder and add it again."
                )
                return
            }

            selectedFolderID = id
            lastLibraryError = nil
            switch record.kind {
            case .folder:   scan(folder: url)
            case .file:     scan(file: url)
            case .playlist: loadPlaylist(id: id, url: url)
            }

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
        scopes.activate(url, requireScope: false)
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

    /// Lädt eine Einzeldatei-Quelle: genau ein Track, kein Verzeichnis-Scan.
    /// `folderURL` bleibt bewusst `nil` — es benennt das Ziel für Ordner-
    /// Aktionen (Import-Drop, Play-Count-Reset), und die gibt es hier nicht.
    func scan(file: URL) {
        scanTask?.cancel()
        cancelPendingWaveformPrefetches()
        folderURL = nil
        fileURL = file
        leavePlaylist()
        tracks = []
        isScanning = true

        scanTask = Task { [file, repository] in
            let loaded = await repository.loadTrack(url: file) ?? Track(url: file)
            if !Task.isCancelled {
                let track = adoptParked(loaded)
                tracks = [track]
                prefetchWaveform(track)
            }
            isScanning = false
        }
    }

    func scan(folder: URL) {
        scanTask?.cancel()
        cancelPendingWaveformPrefetches()
        // `Track.id` wird beim Scan neu vergeben — die Selektion über IDs
        // hinweg zu retten geht also nicht. Die URL ist die stabile Identität,
        // darum die vorher merken und nachher wieder auflösen. Betrifft jeden
        // Refresh: Pull-to-Refresh, Refresh-Knopf, Folder-Mutationen.
        let previouslySelected = Set(
            tracks.filter { selectedTrackIDs.contains($0.id) }
                .map { $0.url.standardizedFileURL }
        )
        folderURL = folder
        fileURL = nil
        leavePlaylist()
        tracks = []
        isScanning = true

        scanTask = Task { [folder, repository] in
            let (stream, _) = await repository.scan(folder: folder)
            if Task.isCancelled { return }
            for await loaded in stream {
                if Task.isCancelled { break }
                let track = adoptParked(loaded)
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
            if !previouslySelected.isEmpty {
                selectedTrackIDs = Set(
                    tracks.filter { previouslySelected.contains($0.url.standardizedFileURL) }
                        .map(\.id)
                )
            }
        }
    }

    var selectedTrack: Track? {
        guard let id = selectedTrackIDs.first else { return nil }
        return tracks.first(where: { $0.id == id })
    }

    /// Liefert alle aktuell selektierten Tracks in Tabellenreihenfolge.
    /// Sinnvoll für Bulk-Aktionen (Re-Analyze, BPM-Scaling, Drag-OUT), die
    /// stabil über die sichtbare Sortierung iterieren sollen.
    var selectedTracks: [Track] {
        tracks.filter { selectedTrackIDs.contains($0.id) && !isUnavailable($0) }
    }

    /// Tracks, bei denen Artist oder Titel fehlt — die Kundschaft der
    /// Metadaten-Ergaenzung. Nur die sichtbaren, wenn ein Filter aktiv ist.
    var tracksMissingTags: [Track] {
        visibleTracks.filter { !isUnavailable($0) && ($0.title.isEmpty || $0.artist.isEmpty) }
    }

    /// Der DB-Actor dient der Metadaten-Kette als Cache fuer Katalog-Antworten.
    var catalogCache: CatalogResponseCache { database }

    /// Kandidaten fuer den Zwillings-Abgleich: **alle** je gescannten Tracks mit
    /// brauchbaren Tags, nicht nur die der offenen Quelle. Genau der wichtigste
    /// Fall liegt sonst ausserhalb — die rohe Kopie im Download-Ordner, die
    /// saubere im Album-Ordner.
    ///
    /// Die Zeilen der offenen Quelle ueberschreiben die aus der DB: sie sind
    /// frischer, weil Edits erst verzoegert geschrieben werden.
    func taggedTracksAcrossLibrary() async -> [Track] {
        var byPath: [String: Track] = [:]
        for track in (try? await database.taggedTracks()) ?? [] {
            byPath[track.url.standardizedFileURL.path] = track
        }
        for track in tracks where !track.artist.isEmpty && !track.title.isEmpty {
            byPath[track.url.standardizedFileURL.path] = track
        }
        return Array(byPath.values)
    }

    /// Uebernimmt die angehakten Felder eines Vorschlags in die Liste und
    /// schreibt sie ueber den normalen Save-Pfad zurueck. Liefert `false`, wenn
    /// der Track nicht mehr in der Liste steht (Quelle gewechselt) oder der
    /// Vorschlag nichts aendert.
    @discardableResult
    func applyMetadata(_ proposal: MetadataProposal) -> Bool {
        guard let idx = tracks.firstIndex(where: { $0.url == proposal.url }) else { return false }
        let updated = proposal.applied(to: tracks[idx])
        guard updated != tracks[idx] else { return false }
        tracks[idx] = updated
        scheduleSave(updated)
        return true
    }

    // MARK: - Navigation

    /// Nächster Track in der aktuell angezeigten Sortierung. Wenn der gerade
    /// geladene Track nicht in der Library ist (z. B. via „Open file…"), wird
    /// auf den ersten Library-Track gesprungen, damit der Knopf trotzdem
    /// etwas Sinnvolles tut.
    func nextTrack(after url: URL?) -> Track? {
        let list = playableTracks
        guard !list.isEmpty else { return nil }
        guard let url, let idx = position(of: url, in: list) else {
            return list.first
        }
        let next = idx + 1
        return next < list.count ? list[next] : nil
    }

    /// Vorheriger Track in der aktuell angezeigten Sortierung. Bei nicht-in-
    /// der-Library-geladenen Tracks Fallback auf den ersten Track.
    func previousTrack(before url: URL?) -> Track? {
        let list = playableTracks
        guard !list.isEmpty else { return nil }
        guard let url, let idx = position(of: url, in: list) else {
            return list.first
        }
        let prev = idx - 1
        return prev >= 0 ? list[prev] : nil
    }

    /// Sichtbare Tracks ohne Playlist-Einträge, deren Datei fehlt.
    private var playableTracks: [Track] {
        visibleTracks.filter { !isUnavailable($0) }
    }

    /// Position des gespielten Tracks. Steht dieselbe Datei mehrfach in einer
    /// Playlist, zählt die ausgewählte Zeile — sonst liefe Auto-Advance nach
    /// dem zweiten Vorkommen wieder hinter das erste und käme nie ans Ende.
    private func position(of url: URL, in list: [Track]) -> Int? {
        list.firstIndex { $0.url == url && selectedTrackIDs.contains($0.id) }
            ?? list.firstIndex { $0.url == url }
    }

    // MARK: - Filter

    /// Suchtext aus dem Filterfeld. Wirkt auf die Tabelle **und** auf
    /// Prev/Next/Auto-Advance — angezeigt und gespielt wird dieselbe Liste.
    /// Ausgewählte Tracks, die der Filter ausblendet, fallen aus der
    /// Selektion, damit Sammelaktionen (Tag-Write, Löschen) nie unsichtbare
    /// Tracks treffen.
    var filterText: String = "" {
        didSet {
            guard filterText != oldValue, !selectedTrackIDs.isEmpty else { return }
            let visibleIDs = Set(visibleTracks.map(\.id))
            selectedTrackIDs.formIntersection(visibleIDs)
        }
    }

    var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `tracks` in aktueller Sortierung, eingeschränkt auf den Filter. Jedes
    /// Wort muss irgendwo vorkommen (Titel, Artist, Album, Genre, Label, Key,
    /// Dateiname), Gross-/Kleinschreibung und Akzente egal.
    var visibleTracks: [Track] {
        let terms = filterText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return tracks }
        return tracks.filter { track in
            let haystack = [
                track.title, track.artist, track.album, track.genre,
                track.label, track.key?.description ?? "", track.fileName
            ].joined(separator: " ")
            return terms.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Re-scannt die aktuell ausgewählte Quelle. Frisst extern hinzugefügte/
    /// entfernte Dateien ein und stellt die aktuelle Sortierung am Ende
    /// wieder her (siehe `scan` → `applySortOrder` nach Stream-Ende).
    func refresh() {
        if let folderURL {
            scan(folder: folderURL)
        } else if let fileURL {
            scan(file: fileURL)
        } else if let playlistURL, let id = selectedFolderID {
            loadPlaylist(id: id, url: playlistURL)
        }
    }

    /// Ob die aktive Quelle neu eingelesen werden kann — für beide Quellenarten.
    var canRefresh: Bool { sourceURL != nil && !isScanning }

    /// Verschiebt (gleiches Volume) bzw. kopiert (volume-übergreifend) per
    /// Drag & Drop in die Liste gezogene Dateien in den aktuell angezeigten
    /// Library-Ordner. Anschliessend wird neu gescannt, damit die Tracks
    /// auftauchen. Tracks im selben Folder werden ignoriert (Self-Drop).
    /// Fehler landen in `lastWriteError`, damit die Toolbar sie zeigt.
    @MainActor
    func importDroppedFiles(_ urls: [URL]) {
        guard let target = folderURL else { return }
        let fm = FileManager.default
        let token = scopes.token(for: target)
        Task { [weak self, target, urls, token] in
            defer { token?.release() }
            var anyImported = false
            for src in urls {
                let src = src.standardizedFileURL
                let dst = target.appendingPathComponent(src.lastPathComponent)
                if src == dst.standardizedFileURL { continue }
                if src.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL {
                    continue // schon im Ziel-Ordner
                }
                // Konflikt-Fall: gleicher Dateiname existiert bereits im
                // Library-Ordner. Wir überschreiben bewusst nicht — das
                // wäre datenzerstörend ohne Rückfrage. Stattdessen klare
                // Meldung. Tritt seit dem Move-Drag-OUT seltener auf, kann
                // aber bei Drop aus dem Finder von einer anderen Quelle
                // weiterhin passieren.
                if fm.fileExists(atPath: dst.path) {
                    await MainActor.run {
                        self?.lastWriteError = String(
                            localized: "‘\(src.lastPathComponent)’ already exists in this folder — skipped."
                        )
                    }
                    continue
                }
                let sameVolume = (try? src.resourceValues(forKeys: [.volumeURLKey]).volume)
                    == (try? target.resourceValues(forKeys: [.volumeURLKey]).volume)
                do {
                    if sameVolume {
                        try fm.moveItem(at: src, to: dst)
                    } else {
                        // Cross-Volume: Foundation kennt keinen atomaren
                        // Move über Volumes, also Copy + Delete der Quelle.
                        // Delete ist best-effort — wenn die Sandbox uns das
                        // Löschen verweigert (Source liegt ausserhalb der
                        // gedroppten/bookmarked Scopes), bleibt die Datei
                        // halt am alten Ort und wir surfacen das als Warnung.
                        try fm.copyItem(at: src, to: dst)
                        do {
                            try fm.removeItem(at: src)
                        } catch {
                            await MainActor.run {
                                self?.lastWriteError = String(
                                    localized: "Imported, but could not remove source ‘\(src.lastPathComponent)’: \(error.localizedDescription)"
                                )
                            }
                        }
                    }
                    anyImported = true
                } catch {
                    await MainActor.run {
                        self?.lastWriteError = String(
                            localized: "Could not import \(src.lastPathComponent): \(error.localizedDescription)"
                        )
                    }
                }
            }
            if anyImported {
                await MainActor.run { self?.scheduleRefresh() }
            }
        }
    }

    /// Bewegt eine Auswahl von Tracks in einen Zielordner. Wird vom
    /// Library-Kontextmenü „Move to Folder…" aufgerufen, weil echtes Move
    /// beim SwiftUI-Drag-OUT auf macOS nicht möglich ist (kein Bridge zu
    /// `NSFilePromiseProvider`). Hier haben wir volle Kontrolle und können
    /// pro Datei entscheiden: same-volume = atomic `moveItem`, cross-volume
    /// = `copyItem` + anschliessendes `removeItem` auf der Quelle.
    /// Konflikte (`fileExists` am Ziel) werden geskippt mit Eintrag in den
    /// Sammel-Fehler — der ErrorChip macht ihn voll lesbar.
    @MainActor
    func moveTracks(_ tracks: [Track], to folder: URL) {
        let fm = FileManager.default
        // Quell-Dateien liegen in der aktiven Quelle — deren Scope muss über
        // den ganzen Move-Lauf offen bleiben.
        let token = scopes.tokenForActiveSource()
        Task { [weak self, tracks, folder, token] in
            defer { token?.release() }
            var failures: [String] = []
            var movedURLs: [URL] = []
            for track in tracks {
                let src = track.url.standardizedFileURL
                let dst = folder.appendingPathComponent(src.lastPathComponent)
                if src == dst.standardizedFileURL { continue }
                if src.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                    continue // schon im Zielordner
                }
                if fm.fileExists(atPath: dst.path) {
                    failures.append(String(
                        localized: "‘\(src.lastPathComponent)’: already exists at destination — skipped."
                    ))
                    continue
                }
                let sameVolume = (try? src.resourceValues(forKeys: [.volumeURLKey]).volume)
                    == (try? folder.resourceValues(forKeys: [.volumeURLKey]).volume)
                do {
                    if sameVolume {
                        try fm.moveItem(at: src, to: dst)
                    } else {
                        try fm.copyItem(at: src, to: dst)
                        // Cross-Volume-Move = Copy + Delete. Wenn Delete
                        // scheitert (z. B. Sandbox / read-only NAS-Mount),
                        // surfacen wir das, aber lassen die Kopie stehen.
                        try fm.removeItem(at: src)
                    }
                    movedURLs.append(src)
                } catch {
                    failures.append("‘\(src.lastPathComponent)’: \(error.localizedDescription)")
                }
            }
            await MainActor.run { [weak self] in
                if !failures.isEmpty {
                    let header = !movedURLs.isEmpty
                        ? String(localized: "Moved \(movedURLs.count); failed for \(failures.count):")
                        : String(localized: "Move failed for \(failures.count):")
                    self?.lastWriteError = ([header] + failures).joined(separator: "\n")
                }
                guard let self, !movedURLs.isEmpty else { return }
                // Die verschobenen Zeilen direkt aus der Liste nehmen, statt den
                // Ordner neu zu scannen. Ein Scan wirft Selektion UND Scroll-
                // Position weg — nach jedem Move muss man dann die Stelle
                // wiederfinden, an der man war. Derselbe Weg, den der
                // Papierkorb-Pfad schon geht.
                self.removeRowsAfterFolderMutation(urls: movedURLs)
                // Landen die Dateien in der gerade angezeigten Quelle, kommen
                // sie dort als neue Zeilen dazu — das sieht nur ein Scan.
                if folder.standardizedFileURL == self.folderURL?.standardizedFileURL {
                    self.scheduleRefresh()
                }
            }
        }
    }

    /// Kopiert eine Auswahl von Tracks in einen Zielordner. Geschwister von
    /// `moveTracks(_:to:)`, nur ohne den Abbau der Quelle — und deshalb
    /// deutlich einfacher: `copyItem` kann Volume-Grenzen von sich aus, der
    /// Vergleich same-volume/cross-volume entfällt.
    ///
    /// Konflikte (`fileExists` am Ziel) werden wie beim Move übersprungen und
    /// gesammelt gemeldet; der ErrorChip macht die Liste voll lesbar. Bewusst
    /// kein automatisches Umbenennen („Track 2.mp3") — in einer DJ-Bibliothek
    /// ist eine stille Dublette schlimmer als eine klare Meldung.
    @MainActor
    func copyTracks(_ tracks: [Track], to folder: URL) {
        let fm = FileManager.default
        // Quell-Dateien liegen in der aktiven Quelle — deren Scope muss über
        // den ganzen Lauf offen bleiben.
        let token = scopes.tokenForActiveSource()
        Task { [weak self, tracks, folder, token] in
            defer { token?.release() }
            var failures: [String] = []
            var copiedCount = 0
            for track in tracks {
                let src = track.url.standardizedFileURL
                let dst = folder.appendingPathComponent(src.lastPathComponent)
                // In den eigenen Ordner kopieren hiesse, die Datei über sich
                // selbst zu legen.
                if src == dst.standardizedFileURL { continue }
                if fm.fileExists(atPath: dst.path) {
                    failures.append(String(
                        localized: "‘\(src.lastPathComponent)’: already exists at destination — skipped."
                    ))
                    continue
                }
                do {
                    try fm.copyItem(at: src, to: dst)
                    copiedCount += 1
                } catch {
                    failures.append("‘\(src.lastPathComponent)’: \(error.localizedDescription)")
                }
            }
            await MainActor.run { [weak self] in
                if !failures.isEmpty {
                    let header = copiedCount > 0
                        ? String(localized: "Copied \(copiedCount); failed for \(failures.count):")
                        : String(localized: "Copy failed for \(failures.count):")
                    self?.lastWriteError = ([header] + failures).joined(separator: "\n")
                }
                // Nur nötig, wenn das Ziel die gerade angezeigte Quelle ist.
                // Das lässt sich sehr wohl feststellen — und ein Refresh ist
                // NICHT billig: er kostet Selektion und Scroll-Position, und
                // seit dem Umbau des Listings zusätzlich eine komplette
                // Neu-Auflistung des Ordners (über eine Netz-Quelle teuer).
                // Beim Kopieren woandershin ändert sich an der Quelle nichts.
                if copiedCount > 0,
                   folder.standardizedFileURL == self?.folderURL?.standardizedFileURL {
                    self?.scheduleRefresh()
                }
            }
        }
    }

    // MARK: - Löschen

    /// Verschiebt die Tracks in den Papierkorb und nimmt sie aus der Liste.
    /// Liefert die Tracks zurück, für die es hier keinen Papierkorb gibt —
    /// typisch auf SMB-/NAS-Mounts. Der Aufrufer muss dafür „endgültig
    /// löschen?" bestätigen lassen und dann `deleteTracksPermanently(_:)`
    /// rufen; stillschweigend endgültig gelöscht wird nie.
    @MainActor
    func moveTracksToTrash(_ tracks: [Track]) async -> (needsConfirmation: [Track], reason: String?) {
        guard !tracks.isEmpty else { return ([], nil) }
        // Die Dateien liegen in der aktiven Quelle — deren Scope muss über den
        // ganzen Lauf offen bleiben, auch wenn zwischendurch gewechselt wird.
        let token = scopes.tokenForActiveSource()
        defer { token?.release() }

        let report = await repository.moveToTrash(tracks)
        applyDeletion(report)
        return (report.trashUnavailable, report.trashFailureReason)
    }

    /// Löscht endgültig. Nur nach ausdrücklicher Bestätigung aufrufen.
    @MainActor
    func deleteTracksPermanently(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        let token = scopes.tokenForActiveSource()
        defer { token?.release() }

        let report = await repository.deletePermanently(tracks)
        applyDeletion(report)
    }

    /// Zieht die Liste und alle Nebenregister auf den Stand nach dem Löschen
    /// nach: geplante Saves für verschwundene Dateien werden abgebrochen,
    /// sonst schreibt der Debounce gleich noch in eine Datei, die es nicht
    /// mehr gibt.
    @MainActor
    private func applyDeletion(_ report: LibraryRepository.DeletionReport) {
        let removedIDs = Set(report.removed.map(\.id))
        if !removedIDs.isEmpty {
            for track in report.removed {
                pendingSaves[track.id]?.cancel()
                pendingSaves.removeValue(forKey: track.id)
                blockedByActivePlayer.remove(track.id)
                orphanedSaves.removeValue(forKey: track.url)?.token?.release()
                let cache = waveformCache
                let url = track.url
                Task { await cache.invalidate(url) }
            }
            unsavedTrackIDs.subtract(removedIDs)
            selectedTrackIDs.subtract(removedIDs)
            tracks.removeAll { removedIDs.contains($0.id) }
        }

        guard !report.failures.isEmpty else {
            if !removedIDs.isEmpty { lastWriteError = nil }
            return
        }
        let header = removedIDs.isEmpty
            ? String(localized: "Delete failed for \(report.failures.count):")
            : String(localized: "Removed \(removedIDs.count); \(report.failures.count) failed:")
        let lines = report.failures.map { "‘\($0.track.url.lastPathComponent)’: \($0.message)" }
        lastWriteError = ([header] + lines).joined(separator: "\n")
    }

    /// Nimmt Zeilen aus der Liste, deren Dateien den Ordner verlassen haben,
    /// und setzt die Selektion auf die Zeile, die deren Platz einnimmt — wie ein
    /// Dateimanager. Ohne das steht der Nutzer nach jedem Move ohne Anker da.
    @MainActor
    private func removeRowsAfterFolderMutation(urls: [URL]) {
        let gone = Set(urls.map { $0.standardizedFileURL })
        guard let firstIndex = tracks.firstIndex(where: { gone.contains($0.url.standardizedFileURL) })
        else { return }

        let removedIDs = Set(tracks.filter { gone.contains($0.url.standardizedFileURL) }.map(\.id))
        tracks.removeAll { removedIDs.contains($0.id) }
        selectedTrackIDs.subtract(removedIDs)

        // Nur nachrücken, wenn die Selektion durch das Entfernen leer wurde.
        // Hat der Nutzer noch etwas anderes markiert, gehört ihm die Auswahl.
        // Bei aktivem Filter nur, wenn der Nachrücker auch sichtbar ist.
        if selectedTrackIDs.isEmpty, !tracks.isEmpty {
            let target = tracks[min(firstIndex, tracks.count - 1)]
            if !isFiltering || visibleTracks.contains(where: { $0.id == target.id }) {
                selectedTrackIDs = [target.id]
            }
        }
    }

    /// Plant einen debouncten `refresh()` ein (Default 250 ms). Sinnvoll,
    /// wenn mehrere Folder-Mutationen parallel passieren — etwa Drag-OUT
    /// mit Multi-Select, wo jeder erfüllte File-Promise einzeln signalisiert
    /// "Folder hat sich geändert". Ohne Debounce würde scan() N-mal laufen.
    private var refreshDebounceTask: Task<Void, Never>?

    @MainActor
    func scheduleRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh() }
        }
    }

    /// Setzt das Rating eines Tracks anhand seiner URL und plant den
    /// gewohnten Debounce-Save ein. Wird vom Player-Rating-Chip aufgerufen,
    /// damit dieselbe Persistenz-Pipeline läuft wie bei einer Inline-Edit
    /// in der Library-Tabelle.
    func setRating(forURL url: URL, _ rating: Rating) {
        guard let idx = tracks.firstIndex(where: { $0.url == url && !isUnavailable($0) }) else { return }
        guard tracks[idx].rating != rating else { return }
        tracks[idx].rating = rating
        scheduleSave(tracks[idx])
    }

    // MARK: - Persistence

    /// Vom UI nach jeder Mutation aufrufen. Mehrere schnelle Aufrufe für
    /// denselben Track werden zu einem einzigen Schreibvorgang gebündelt.
    func scheduleSave(_ track: Track) {
        // Playlist-Eintrag ohne Datei: es gibt nichts zu schreiben.
        guard !isUnavailable(track) else { return }
        mirrorToDuplicates(track)
        unsavedTrackIDs.insert(track.id)
        pendingSaves[track.id]?.cancel()
        let debounce = saveDebounce
        // Token schon jetzt nehmen, nicht erst nach dem Debounce: der Edit
        // gehört zu der Quelle, die beim Tippen sichtbar war.
        let token = scopes.token(for: track.url)
        pendingSaves[track.id] = Task { [weak self, track, token] in
            defer { token?.release() }
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self?.performSave(track)
        }
    }

    /// Manueller Speicher-Befehl (z. B. ⌘S oder Toolbar-Knopf): bricht das
    /// Debouncing ab und schreibt alle aktuell dirty Tracks sofort.
    func saveAllNow() {
        Task { [weak self] in await self?.saveAllNowAndWait() }
    }

    /// Wie `saveAllNow()`, kehrt aber erst zurück, wenn alles auf der Platte
    /// ist. Daran hängt der Beenden-Dialog: „Speichern" darf die App nicht
    /// beenden, bevor der letzte Tag-Write durch ist.
    ///
    /// Sequenziell, weil `TagLibTrackStore` die Schreibvorgänge ohnehin
    /// serialisiert — parallele Tasks brächten hier nichts ausser
    /// Unübersichtlichkeit.
    func saveAllNowAndWait() async {
        for (_, task) in pendingSaves { task.cancel() }
        pendingSaves.removeAll()
        let dirty = unsavedTrackIDs
        for id in dirty {
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            let token = scopes.token(for: track.url)
            await performSave(track)
            token?.release()
        }
    }

    private func performSave(_ track: Track) async {
        guard !isUnavailable(track) else { return }
        // Safety-Net: hält den Scope mindestens für die Dauer des
        // Schreibvorgangs fest, auch wenn der Aufrufer keinen Token hielt.
        let token = scopes.token(for: track.url)
        defer { token?.release() }
        do {
            try await repository.save(track)
            unsavedTrackIDs.remove(track.id)
            blockedByActivePlayer.remove(track.id)
            unpark(track)
            lastWriteError = nil
        } catch let error as TagLibTrackStore.StoreError {
            if case .fileInUse = error {
                // Track ist gerade im Player aktiv: roten Punkt stehen
                // lassen, Schreiben wird beim Entladen automatisch nachgeholt.
                // Zusätzlich über die URL parken, falls der Track bis dahin
                // nicht mehr in der Liste steht.
                blockedByActivePlayer.insert(track.id)
                park(track)
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
                self.flushOrphanedSaves(activeURL: url)
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
            // Der Track steht noch in der Liste — die geparkte Kopie wäre
            // ein zweiter Write desselben Stands.
            var token: SecurityScope.Token?
            if let parked = orphanedSaves[track.url], parked.track.id == id {
                orphanedSaves.removeValue(forKey: track.url)
                token = parked.token
            }
            token = token ?? scopes.token(for: track.url)
            Task { [weak self, track, token] in
                defer { token?.release() }
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
        guard !isUnavailable(track) else { return }
        prefetchWaveform(track)

        // DJ-Mix: BPM und Key ergeben über einen ganzen Mix keinen Sinn, und
        // die Analyse würde Minuten und über ein Gigabyte Speicher kosten.
        // Ein ausdrücklicher `reanalyze` läuft weiterhin durch — wer es
        // trotzdem anstösst, hat sich dafür entschieden.
        guard !track.isLikelyDJMix else { return }

        let needsBPM = track.bpm == nil
        let needsKey = track.key == nil
        guard needsBPM || needsKey else { return }
        if analysesInFlight.contains(track.url) { return }

        analysesInFlight.insert(track.url)
        let preset = bpmPreset
        let analyzer = analyzer
        // Analyse liest die Datei und schreibt danach Tags — beides braucht
        // den Scope der Quelle, aus der der Track stammt. Wechselt der Nutzer
        // zwischendurch den Ordner, hält dieses Token ihn offen.
        let token = scopes.token(for: track.url)

        Task { [weak self, track, needsBPM, needsKey, preset, token] in
            defer {
                token?.release()
                self?.analysesInFlight.remove(track.url)
            }
            do {
                let result = try await analyzer.analyze(
                    url: track.url,
                    needsBPM: needsBPM,
                    needsKey: needsKey,
                    bpmRange: preset
                )
                let landedInList = await MainActor.run { [weak self] () -> Bool in
                    guard let self else { return true }
                    let landed = self.applyAnalysis(result, toRowFor: track.url)
                    // „Kein BPM gefunden" nur melden, solange der Track auch
                    // sichtbar ist. Sonst stünde in der Statuszeile eine
                    // Meldung über eine Datei aus dem verlassenen Ordner.
                    guard landed else { return false }
                    let gotBPM = result.bpm != nil
                    let gotKey = result.key != nil
                    if needsBPM && !gotBPM && needsKey && !gotKey {
                        self.lastAnalysisError = String(localized: "No BPM and no key detected: \(track.url.lastPathComponent)")
                    } else if needsBPM && !gotBPM {
                        self.lastAnalysisError = String(localized: "No BPM detected: \(track.url.lastPathComponent)")
                    } else if needsKey && !gotKey {
                        self.lastAnalysisError = String(localized: "No key detected: \(track.url.lastPathComponent)")
                    } else {
                        self.lastAnalysisError = nil
                    }
                    return true
                }
                if !landedInList {
                    await self?.persistOrphanedAnalysis(result, forURL: track.url)
                }
            } catch {
                await MainActor.run {
                    self?.lastAnalysisError = error.localizedDescription
                }
            }
        }
    }

    /// Bulk-Trigger: stösst für jeden Track die Waveform-Vorberechnung an und
    /// — falls BPM oder Key fehlen — zusätzlich die Audio-Analyse. Der
    /// nil-Guard in `analyzeIfNeeded` sorgt dafür, dass die teure aubio/
    /// KeyFinder-Pipeline nur dort läuft, wo wirklich etwas fehlt.
    /// Bei aktivem Filter nur die sichtbaren Tracks.
    func analyzeAllMissing() {
        for track in visibleTracks {
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
        guard !isUnavailable(track) else { return }
        prefetchWaveform(track, force: true)
        if analysesInFlight.contains(track.url) { return }

        analysesInFlight.insert(track.url)
        let preset = bpmPreset
        let analyzer = analyzer
        let token = scopes.token(for: track.url)

        Task { [weak self, track, preset, token] in
            defer {
                token?.release()
                self?.analysesInFlight.remove(track.url)
            }
            do {
                let result = try await analyzer.analyze(
                    url: track.url,
                    needsBPM: true,
                    needsKey: true,
                    bpmRange: preset
                )
                let landedInList = await MainActor.run { [weak self] () -> Bool in
                    guard let self else { return true }
                    let landed = self.applyAnalysis(result, toRowFor: track.url)
                    // Siehe `analyzeIfNeeded`: keine Meldungen über Dateien,
                    // die gar nicht mehr angezeigt werden.
                    guard landed else { return false }
                    if result.bpm == nil && result.key == nil {
                        self.lastAnalysisError = String(localized: "No BPM and no key detected: \(track.url.lastPathComponent)")
                    } else {
                        self.lastAnalysisError = nil
                    }
                    return true
                }
                if !landedInList {
                    await self?.persistOrphanedAnalysis(result, forURL: track.url)
                }
            } catch {
                await MainActor.run {
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
    private func prefetchWaveform(_ track: Track, force: Bool = false) {
        guard !isUnavailable(track) else { return }
        // DJ-Mixes nicht im Hintergrund vorrechnen: `PCMLoader` hält die
        // ganze Datei dekodiert im RAM (~1,3 GB bei zwei Stunden), und bis
        // zu drei Prefetches laufen parallel. Die Welle entsteht stattdessen
        // erst, wenn der Track wirklich in den Player geladen wird.
        guard force || !track.isLikelyDJMix else { return }

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
            let token = scopes.token(for: url)
            Task.detached(priority: .utility) { [weak self, token] in
                defer { token?.release() }
                _ = try? await cache.waveform(for: url)
                await self?.finishWaveformPrefetch(url)
            }
        }
    }

    /// Gibt den Platz in der Prefetch-Drosselung wieder frei und lässt den
    /// nächsten Eintrag nachrücken.
    @MainActor
    private func finishWaveformPrefetch(_ url: URL) {
        waveformPrefetchInflight.remove(url)
        pumpWaveformPrefetchQueue()
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
    /// Trägt ein Analyse-Ergebnis in die sichtbare Zeile ein und schreibt es
    /// zurück. Gesucht wird über die **URL**: `Track.id` wird bei jedem Scan
    /// neu vergeben (`Track.init` vergibt eine frische UUID, kein Aufrufer
    /// übergibt je eine), überlebt also weder Ordnerwechsel noch Refresh.
    /// Über die URL landet ein spät eintreffendes Ergebnis auch dann richtig,
    /// wenn der Ordner zwischenzeitlich neu gescannt wurde.
    ///
    /// `false`, wenn es die Zeile nicht mehr gibt — dann übernimmt
    /// `persistOrphanedAnalysis`.
    @MainActor
    private func applyAnalysis(_ result: AnalysisCoordinator.Result, toRowFor url: URL) -> Bool {
        guard let idx = tracks.firstIndex(where: { $0.url == url && !isUnavailable($0) }) else { return false }
        var updated = tracks[idx]
        if let bpm = result.bpm { updated.bpm = bpm }
        if let key = result.key { updated.key = key }
        tracks[idx] = updated
        if result.bpm != nil || result.key != nil {
            persistAfterAnalysis(updated)
            onTrackAnalyzed?(updated)
        }
        return true
    }

    /// Sichert ein Ergebnis, dessen Track nicht mehr in der Liste steht —
    /// der Nutzer hat den Ordner gewechselt, refresht oder importiert,
    /// während die Analyse lief. Ohne das wäre die ganze Rechenarbeit weg und
    /// die Datei würde beim nächsten Besuch des Ordners erneut analysiert.
    ///
    /// Der aktuelle Stand wird **frisch aus dem Repository** geholt, statt die
    /// im Task eingefrorene Kopie zu schreiben: sonst überschriebe ein spätes
    /// Analyse-Ergebnis Tag-Edits, die der Nutzer zwischendurch gemacht hat.
    /// Aufgesetzt werden nur BPM und Key.
    private func persistOrphanedAnalysis(_ result: AnalysisCoordinator.Result, forURL url: URL) async {
        guard result.bpm != nil || result.key != nil else { return }
        let token = scopes.token(for: url)
        defer { token?.release() }

        guard var fresh = await repository.loadTrack(url: url) else { return }
        if let bpm = result.bpm { fresh.bpm = bpm }
        if let key = result.key { fresh.key = key }

        do {
            try await repository.save(fresh)
            lastWriteError = nil
        } catch let error as TagLibTrackStore.StoreError {
            if case .fileInUse = error {
                // Datei läuft gerade im Player. `blockedByActivePlayer` hilft
                // hier nicht — das geht über die Scan-ID, die es für diesen
                // Track nicht mehr gibt. Also über die URL parken und beim
                // nächsten Player-Wechsel nachholen.
                park(fresh)
            } else {
                lastWriteError = error.localizedDescription
            }
        } catch {
            lastWriteError = error.localizedDescription
        }
    }

    /// Schreibt geparkte Ergebnisse, sobald der Player die jeweilige Datei
    /// nicht mehr hält.
    private func flushOrphanedSaves(activeURL: URL?) {
        let due = orphanedSaves.filter { $0.key != activeURL }
        for (url, parked) in due {
            orphanedSaves.removeValue(forKey: url)
            blockedByActivePlayer.remove(parked.track.id)
            let track = parked.track
            let token = parked.token ?? scopes.token(for: url)
            Task { [weak self, track, token] in
                defer { token?.release() }
                await self?.performSave(track)
            }
        }
    }

    private func persistAfterAnalysis(_ track: Track) {
        mirrorToDuplicates(track)
        unsavedTrackIDs.insert(track.id)
        pendingSaves[track.id]?.cancel()
        pendingSaves[track.id] = nil
        let token = scopes.token(for: track.url)
        Task { [weak self, track, token] in
            defer { token?.release() }
            await self?.performSave(track)
        }
    }
}
