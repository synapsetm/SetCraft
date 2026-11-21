//
//  ContentView.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 03.06.2026.
//

import SwiftUI
import SetCraftCore
import UniformTypeIdentifiers

struct ContentView: View {
    let libraryStore: LibraryStore
    let playerStore: PlayerStore

    @State private var selectedTab: AppTab = .library

    enum AppTab: Hashable { case library, player }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryScreen(
                libraryStore: libraryStore,
                playerStore: playerStore,
                selectedTab: $selectedTab
            )
            .tabItem {
                Label("Library", systemImage: "list.bullet")
            }
            .tag(AppTab.library)
            .toolbar(.hidden, for: .tabBar)

            PlayerScreen(store: playerStore)
                .tabItem {
                    Label("Player", systemImage: "waveform")
                }
                .tag(AppTab.player)
                .toolbar(.hidden, for: .tabBar)
        }
        .tint(Theme.Palette.accent)
        // Eigene Tab-Leiste nach Mockup statt der schwebenden Glas-Kapsel
        // von iOS 26, deren Beschriftung sich nicht gestalten lässt.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ThemeTabBar(selection: $selectedTab)
        }
    }
}

/// Flache Tab-Leiste über die ganze Breite: Trennlinie oben, Symbol und
/// Beschriftung in Grossbuchstaben, aktiver Tab in `accent`.
private struct ThemeTabBar: View {
    @Binding var selection: ContentView.AppTab

    var body: some View {
        VStack(spacing: 0) {
            Theme.Palette.border.frame(height: 1)
            HStack(spacing: 0) {
                item(.library, title: "Library", symbol: "list.bullet")
                item(.player, title: "Player", symbol: "waveform.path")
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .background(Theme.Palette.background.ignoresSafeArea(edges: .bottom))
    }

    private func item(_ tab: ContentView.AppTab, title: LocalizedStringKey, symbol: String) -> some View {
        let isOn = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.4)
                    .textCase(.uppercase)
            }
            .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textMuted)
            .frame(maxWidth: .infinity, minHeight: Theme.MetricsIOS.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Sheet-Auswahl für die Library: Info (read-only Datei-Eigenschaften) oder
/// Edit (TagEditSheet). Identifiable über `<typ>-<trackId>` damit SwiftUI
/// beim Wechsel sauber neu mounted.
private enum LibrarySheet: Identifiable {
    case info(Track)
    case edit(Track)

    var id: String {
        switch self {
        case .info(let t): return "info-\(t.id)"
        case .edit(let t): return "edit-\(t.id)"
        }
    }
}

private struct LibraryScreen: View {
    let libraryStore: LibraryStore
    let playerStore: PlayerStore
    @Binding var selectedTab: ContentView.AppTab

    @State private var showFolderImporter = false
    @State private var activeSheet: LibrarySheet?
    @State private var showResetConfirm = false
    /// Tracks, die auf die Papierkorb-Bestätigung warten.
    @State private var pendingTrashTracks: [Track] = []
    @State private var showTrashConfirm = false
    /// Tracks, für die es hier keinen Papierkorb gibt — warten auf die
    /// zweite, ausdrückliche Bestätigung „endgültig löschen".
    @State private var pendingPermanentTracks: [Track] = []
    @State private var permanentReason: String?
    @State private var showPermanentConfirm = false
    /// Als DJ-Mix erkannte Tracks, für die eine Analyse angefordert wurde
    /// und die auf die Rückfrage warten.
    @State private var pendingMixAnalysis: [Track] = []
    @State private var showMixAnalysisConfirm = false
    /// Lauf der Tag-Ergaenzung. Pro Aufruf neu gebaut, damit ein zweites
    /// Oeffnen nicht die Vorschlaege des letzten Laufs zeigt.
    @State private var fixStore: MetadataFixStore?
    /// Filter über Titel und Artist — reine Anzeige, der Store bleibt unberührt.
    @State private var filterText = ""
    @Environment(\.verticalSizeClass) private var vSizeClass

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Palette.background)
                // Eigene Kopfzeile statt Navigationsleiste: iOS 26 legt
                // Toolbar-Items sonst in Glas-Kapseln, die nicht zum eckigen
                // Amber-Stil passen.
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if vSizeClass == .compact {
                            // Querformat: Marke, Quelle und ••• in einer
                            // Zeile, damit mehr Platz für Tracks bleibt.
                            header
                            Theme.Palette.border.frame(height: 1)
                        } else {
                            header
                            Theme.Palette.border.frame(height: 1)
                            if !libraryStore.folders.isEmpty {
                                sourceRow
                                Theme.Palette.border.frame(height: 1)
                            }
                        }
                        MasterTempoBar(masterBPM: Binding(
                            get: { playerStore.masterBPM },
                            set: { playerStore.masterBPM = $0 }
                        ))
                        Theme.Palette.border.frame(height: 1)
                    }
                    .background(Theme.Palette.background)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if playerStore.currentTrack != nil {
                        MiniPlayerView(store: playerStore) {
                            selectedTab = .player
                        }
                    }
                }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    libraryStore.lastError = String(localized: "Picker: no URL returned.")
                    return
                }
                Task { await libraryStore.addFolder(url: url) }
            case .failure(let error):
                libraryStore.lastError = String(localized: "Picker failed: \(error.localizedDescription)")
            }
        }
        .confirmationDialog(
            "Reset play counts for this source?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await libraryStore.resetPlayCountsInCurrentFolder() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let folder = libraryStore.selectedFolder {
                Text("All tracks in “\(folder.name)” will have their play count set back to 0.")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .info(let track):
                TrackInfoSheet(track: track)
            case .edit(let track):
                TagEditSheet(track: track) { updated in
                    Task { await libraryStore.updateTrack(updated) }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { fixStore != nil },
            set: { if !$0 { fixStore = nil } }
        )) {
            if let fixStore {
                MetadataFixSheet(store: fixStore) {
                    self.fixStore = nil
                }
            }
        }
        .task {
            await libraryStore.restoreSavedFolders()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let folder = libraryStore.selectedFolder {
            trackList(for: folder)
        } else {
            let baseDesc = String(localized: "Tap “Open folder…” to add a music folder. NAS/SMB shares mounted via the Files app are transparently supported.")
            let errorTail = libraryStore.lastError.map { "\n\n⚠️ \($0)" } ?? ""
            ContentUnavailableView {
                Label("No source selected", systemImage: "folder.badge.plus")
            } description: {
                Text(baseDesc + errorTail)
            } actions: {
                Button("Open folder…") { showFolderImporter = true }
            }
        }
    }

    @ViewBuilder
    private func trackList(for folder: FolderRecord) -> some View {
        if libraryStore.tracks.isEmpty && libraryStore.isScanning {
            // Bis der erste Track eintrifft, gab es hier eine leere `List` —
            // ein blankes Nichts, das beim App-Start über Mobilfunk wie eine
            // eingefrorene App aussah. Das Listing selbst läuft inzwischen
            // nicht mehr auf dem MainActor, der Spinner dreht sich also auch.
            ContentUnavailableView {
                Label {
                    Text("Loading library…")
                } icon: {
                    ProgressView()
                }
            } description: {
                Text("Reading the folder. With many tracks on a network source this can take a moment.")
            }
        } else if libraryStore.tracks.isEmpty && !libraryStore.isScanning {
            let base = String(localized: "The folder “\(folder.name)” contains no recognized audio files.")
            let detail = libraryStore.lastError.map { "\n\n\($0)" } ?? ""
            ContentUnavailableView(
                "No tracks",
                systemImage: "music.note",
                description: Text(base + detail)
            )
        } else {
            VStack(spacing: 0) {
            // Im Querformat kein Filterfeld — sonst bleibt unter den
            // Kopfzeilen kaum Platz für Tracks. Ein aktiver Filter bleibt
            // sichtbar, damit klar ist, warum die Liste gekürzt ist.
            if vSizeClass != .compact || !filterText.isEmpty {
                filterBar
            }
            sortHeader
            List {
                if let error = libraryStore.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.issueText)
                        .listRowBackground(Theme.Palette.background)
                }
                ForEach(filteredTracks) { track in
                    // Match über URL — Track.id wird beim Scan/Cache-Read
                    // neu vergeben, URL ist die stabile Identität.
                    let isCurrent = playerStore.currentTrack?.url == track.url
                    TrackRowView(
                        track: track,
                        isCurrent: isCurrent,
                        isPlaying: isCurrent && playerStore.isPlaying,
                        isLoading: playerStore.loadingURL == track.url,
                        isAnalyzing: libraryStore.isAnalyzing(trackID: track.id),
                        // Master-Tempo gilt für jeden Track, der geöffnet wird
                        // — die Liste zeigt also durchgehend, wie die Tonarten
                        // dann klingen.
                        sounding: track.playingKey(in: libraryStore.soundingContext)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playerStore.load(track)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            activeSheet = .info(track)
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }
                        .tint(Theme.Palette.borderStrong)

                        Button {
                            activeSheet = .edit(track)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(Theme.Palette.textMuted)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Kein Full-Swipe fürs Löschen: die Rückfrage kommt
                        // ohnehin, aber ein versehentlicher Vollswipe soll
                        // sie gar nicht erst auslösen.
                        Button(role: .destructive) {
                            pendingTrashTracks = [track]
                            showTrashConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            requestAnalyze([track])
                        } label: {
                            Label("Analyze", systemImage: "wand.and.stars")
                        }
                        .tint(Theme.Palette.accent)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if filteredTracks.isEmpty && !filterText.isEmpty {
                    ContentUnavailableView.search(text: filterText)
                }
            }
            .refreshable {
                await libraryStore.refresh()
            }
            }
            .confirmationDialog(
                trashConfirmTitle,
                isPresented: $showTrashConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let victims = pendingTrashTracks
                    pendingTrashTracks = []
                    Task {
                        // Quellen ohne Papierkorb (NAS/SMB über die Files-App)
                        // melden sich hier zurück — dann fragen wir ein zweites
                        // Mal, statt stillschweigend endgültig zu löschen.
                        let (needsConfirmation, reason) = await libraryStore.moveTracksToTrash(victims)
                        guard !needsConfirmation.isEmpty else { return }
                        pendingPermanentTracks = needsConfirmation
                        permanentReason = reason
                        showPermanentConfirm = true
                    }
                }
                Button("Cancel", role: .cancel) { pendingTrashTracks = [] }
            } message: {
                Text("Removed from disk, not just from the library.")
            }
            .confirmationDialog(
                "Delete this file permanently?",
                isPresented: $showPermanentConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    let victims = pendingPermanentTracks
                    pendingPermanentTracks = []
                    Task { await libraryStore.deleteTracksPermanently(victims) }
                }
                Button("Cancel", role: .cancel) { pendingPermanentTracks = [] }
            } message: {
                Text(permanentConfirmMessage)
            }
            .confirmationDialog(
                mixAnalysisTitle,
                isPresented: $showMixAnalysisConfirm,
                titleVisibility: .visible
            ) {
                Button("Analyze") {
                    let tracks = pendingMixAnalysis
                    pendingMixAnalysis = []
                    for track in tracks {
                        Task { await libraryStore.analyze(trackID: track.id) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingMixAnalysis = [] }
            } message: {
                Text("BPM and key say little about a whole mix, and the analysis takes several minutes per file.")
            }
        }
    }

    /// Startet die Analyse. Tracks, die als DJ-Mix erkannt sind, laufen nicht
    /// einfach mit: über einen ganzen Mix sagen BPM und Key wenig aus, und die
    /// Analyse dauert Minuten pro Datei. Der Weg bleibt offen — aber als
    /// bewusste Antwort auf eine Rückfrage.
    private func requestAnalyze(_ tracks: [Track]) {
        for track in tracks where !track.isLikelyDJMix {
            Task { await libraryStore.analyze(trackID: track.id) }
        }
        let mixes = tracks.filter(\.isLikelyDJMix)
        guard !mixes.isEmpty else { return }
        pendingMixAnalysis = mixes
        showMixAnalysisConfirm = true
    }

    private var mixAnalysisTitle: String {
        if pendingMixAnalysis.count == 1, let track = pendingMixAnalysis.first {
            return String(localized: "“\(track.displayTitle)” is a DJ mix — analyze anyway?")
        }
        return String(localized: "\(pendingMixAnalysis.count) tracks are DJ mixes — analyze anyway?")
    }

    private var trashConfirmTitle: String {
        guard let track = pendingTrashTracks.first else { return "" }
        return String(localized: "Move “\(track.displayTitle)” to the Trash?")
    }

    private var permanentConfirmMessage: String {
        let reason = permanentReason ?? String(localized: "The Trash is not available on this volume.")
        return reason + "\n\n" + String(localized: "Permanent deletion cannot be undone.")
    }

    private func statusLine(for folder: FolderRecord) -> String {
        let count = "\(libraryStore.tracks.count) tracks"
        return libraryStore.isScanning ? "\(count) · scanning…" : count
    }

    /// Quellenzeile unter dem Kopf: Nummer, Name, Anzahl. Antippen öffnet das
    /// Quellen-Menü — Auswahl, Entfernen und «Open folder…», die früher im
    /// Toolbar-Menü lagen (I1-Spec, Funktionsinventar Library).
    private var sourceRow: some View {
        Menu {
            Section("Sources") {
                ForEach(Array(libraryStore.folders.enumerated()), id: \.element.id) { index, folder in
                    Button {
                        Task { await libraryStore.selectFolder(id: folder.id) }
                    } label: {
                        let title = "\(Self.sourceNumber(index))  \(folder.name)"
                        if folder.id == libraryStore.selectedFolderID {
                            Label { Text(verbatim: title) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: title)
                        }
                    }
                }
            }
            Section("Remove") {
                ForEach(libraryStore.folders) { folder in
                    Button(role: .destructive) {
                        Task { await libraryStore.removeFolder(id: folder.id) }
                    } label: {
                        Label(folder.name, systemImage: "trash")
                    }
                }
            }
            Divider()
            Button {
                showFolderImporter = true
            } label: {
                Label("Open folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 10) {
                if let folder = libraryStore.selectedFolder {
                    let index = libraryStore.folders.firstIndex(where: { $0.id == folder.id }) ?? 0
                    Text(verbatim: Self.sourceNumber(index))
                        .font(Theme.TypoIOS.bodyNumeric.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(folder.name)
                        .font(Theme.TypoIOS.body.weight(.medium))
                        .foregroundStyle(Theme.Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                } else {
                    Text("No source selected")
                        .font(Theme.TypoIOS.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textMuted)
                Spacer(minLength: 8)
                if let folder = libraryStore.selectedFolder {
                    Text(statusLine(for: folder))
                        .themeLabel()
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.MetricsIOS.padding)
            .frame(minHeight: Theme.MetricsIOS.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tracks nach Filter. Leerer Filter = alle, in Store-Reihenfolge.
    private var filteredTracks: [Track] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return libraryStore.tracks }
        return libraryStore.tracks.filter {
            $0.displayTitle.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
        }
    }

    /// Tracks ohne BPM oder Key — Ziel des «ANALYZE n»-Buttons.
    private var tracksMissingAnalysis: [Track] {
        libraryStore.tracks.filter { $0.bpm == nil || $0.key == nil }
    }

    /// Filterfeld und «ANALYZE n» über der Liste.
    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textMuted)
                TextField("Filter \(libraryStore.tracks.count) tracks", text: $filterText)
                    .font(Theme.TypoIOS.body)
                    .foregroundStyle(Theme.Palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.textMuted)
                            .frame(width: 28, height: Theme.MetricsIOS.minTouch)
                    }
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.MetricsIOS.minTouch)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Palette.border, lineWidth: 1))

            let missing = tracksMissingAnalysis
            if !missing.isEmpty {
                Button("Analyze \(missing.count)") {
                    requestAnalyze(missing)
                }
                .buttonStyle(ThemeButtonStyle(height: Theme.MetricsIOS.minTouch, kind: .accentOutline))
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.MetricsIOS.padding)
        .padding(.vertical, 8)
    }

    /// Sortierhinweis über der Liste: aktives Kriterium links, Spalten rechts.
    /// Bewertung und Datum sortieren absteigend (siehe `applySortOrder`).
    private var sortHeader: some View {
        let field = libraryStore.sortField
        let descending = field == .rating || field == .modified
        return VStack(spacing: 0) {
            HStack {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(field.rawValue))
                    Text(verbatim: descending ? "↓" : "↑")
                }
                .themeLabel()
                Spacer()
                Text(verbatim: "BPM · KEY")
                    .themeLabel()
            }
            .padding(.horizontal, Theme.MetricsIOS.padding)
            .padding(.vertical, 6)
            Theme.Palette.border.frame(height: 1)
        }
    }

    /// «01», «02», … wie die Sidebar der Mac-App.
    private static func sourceNumber(_ index: Int) -> String {
        String(format: "%02d", index + 1)
    }

    /// Kopfzeile: Marke links, Aktionen-Menü rechts.
    private var header: some View {
        HStack(spacing: 0) {
            Text(verbatim: "SETCRAFT")
                .font(Theme.TypoIOS.brand)
                .tracking(Theme.Typo.brandTracking)
                .foregroundStyle(Theme.Palette.accent)
                .fixedSize()
            if vSizeClass == .compact && !libraryStore.folders.isEmpty {
                sourceRow
            } else {
                Spacer()
            }
            actionsMenu
        }
        .padding(.leading, Theme.MetricsIOS.padding)
        .padding(.trailing, 4)
    }

    private var actionsMenu: some View {
            Menu {
                Section("Sort by") {
                    ForEach(LibraryStore.SortField.allCases) { field in
                        Button {
                            libraryStore.sortField = field
                        } label: {
                            // rawValue ist ein String — über LocalizedStringKey
                            // den Catalog-Lookup erzwingen, damit „Title" usw.
                            // im DE-Build als „Titel" erscheinen.
                            if libraryStore.sortField == field {
                                Label(LocalizedStringKey(field.rawValue), systemImage: "checkmark")
                            } else {
                                Text(LocalizedStringKey(field.rawValue))
                            }
                        }
                    }
                }

                if !libraryStore.tracks.isEmpty {
                    Button {
                        requestAnalyze(libraryStore.tracks)
                    } label: {
                        Label("Analyze all", systemImage: "wand.and.stars")
                    }
                    Button {
                        fixStore = MetadataFixStore(library: libraryStore)
                    } label: {
                        let missing = libraryStore.tracksMissingTags.count
                        Label(
                            missing > 0 ? "Complete tags (\(missing))" : "Complete tags",
                            systemImage: "text.badge.checkmark"
                        )
                    }
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Reset play counts", systemImage: "arrow.counterclockwise.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.text)
                    .frame(width: Theme.MetricsIOS.minTouch, height: Theme.MetricsIOS.minTouch)
                    .contentShape(Rectangle())
            }
    }
}


