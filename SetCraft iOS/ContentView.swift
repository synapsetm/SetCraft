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

            PlayerScreen(store: playerStore)
                .tabItem {
                    Label("Player", systemImage: "waveform")
                }
                .tag(AppTab.player)
        }
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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(libraryStore.selectedFolder?.name ?? "Library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    sourceMenu
                    ToolbarItem(placement: .principal) {
                        if let folder = libraryStore.selectedFolder {
                            VStack(spacing: 0) {
                                Text(folder.name)
                                    .font(.system(size: 14, weight: .medium))
                                Text(statusLine(for: folder))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await libraryStore.addFolder(url: url) }
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
        .task {
            await libraryStore.restoreSavedFolders()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let folder = libraryStore.selectedFolder {
            trackList(for: folder)
        } else {
            ContentUnavailableView {
                Label("Keine Quelle aktiv", systemImage: "folder.badge.plus")
            } description: {
                Text("Tippe oben rechts auf das Menü, dann „Open folder…\". NAS/SMB-Shares aus der Files-App werden transparent unterstützt.")
            } actions: {
                Button("Open folder…") { showFolderImporter = true }
            }
        }
    }

    @ViewBuilder
    private func trackList(for folder: FolderRecord) -> some View {
        if libraryStore.tracks.isEmpty && !libraryStore.isScanning {
            let base = "Der Ordner „\(folder.name)\" enthält keine erkannten Audio-Dateien."
            let detail = libraryStore.lastError.map { "\n\n\($0)" } ?? ""
            ContentUnavailableView(
                "Keine Tracks",
                systemImage: "music.note",
                description: Text(base + detail)
            )
        } else {
            List {
                if let error = libraryStore.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
                ForEach(libraryStore.sortedTracks) { track in
                    TrackRowView(
                        track: track,
                        isPlaying: playerStore.currentTrack?.id == track.id && playerStore.isPlaying,
                        isAnalyzing: libraryStore.isAnalyzing(trackID: track.id)
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
                        .tint(.gray)

                        Button {
                            activeSheet = .edit(track)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            Task { await libraryStore.analyze(trackID: track.id) }
                        } label: {
                            Label("Analyze", systemImage: "wand.and.stars")
                        }
                        .tint(.blue)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func statusLine(for folder: FolderRecord) -> String {
        let count = "\(libraryStore.tracks.count) tracks"
        return libraryStore.isScanning ? "\(count) · scanning…" : count
    }

    @ToolbarContentBuilder
    private var sourceMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Sort by") {
                    ForEach(LibraryStore.SortField.allCases) { field in
                        Button {
                            libraryStore.sortField = field
                        } label: {
                            if libraryStore.sortField == field {
                                Label(field.rawValue, systemImage: "checkmark")
                            } else {
                                Text(field.rawValue)
                            }
                        }
                    }
                }

                if !libraryStore.folders.isEmpty {
                    Section("Sources") {
                        ForEach(libraryStore.folders) { folder in
                            Button {
                                Task { await libraryStore.selectFolder(id: folder.id) }
                            } label: {
                                if folder.id == libraryStore.selectedFolderID {
                                    Label(folder.name, systemImage: "checkmark")
                                } else {
                                    Text(folder.name)
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
                }

                Button {
                    showFolderImporter = true
                } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
