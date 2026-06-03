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

    var body: some View {
        TabView {
            LibraryScreen(store: libraryStore)
                .tabItem {
                    Label("Library", systemImage: "list.bullet")
                }

            PlayerScreen()
                .tabItem {
                    Label("Player", systemImage: "waveform")
                }
        }
    }
}

private struct LibraryScreen: View {
    let store: LibraryStore
    @State private var showFolderImporter = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar { sourceMenu }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await store.addFolder(url: url) }
        }
        .task {
            await store.restoreSavedFolders()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let folder = store.selectedFolder {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name)
                        .font(.title3.weight(.semibold))
                    Text(statusLine(for: folder))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let error = store.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("Track-Liste kommt in Phase 5b.2.d.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
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

    private func statusLine(for folder: FolderRecord) -> String {
        let count = "\(store.tracks.count) tracks"
        return store.isScanning ? "\(count) · scanning…" : count
    }

    @ToolbarContentBuilder
    private var sourceMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !store.folders.isEmpty {
                    Section("Sources") {
                        ForEach(store.folders) { folder in
                            Button {
                                Task { await store.selectFolder(id: folder.id) }
                            } label: {
                                if folder.id == store.selectedFolderID {
                                    Label(folder.name, systemImage: "checkmark")
                                } else {
                                    Text(folder.name)
                                }
                            }
                        }
                    }
                    if !store.folders.isEmpty {
                        Section("Remove") {
                            ForEach(store.folders) { folder in
                                Button(role: .destructive) {
                                    Task { await store.removeFolder(id: folder.id) }
                                } label: {
                                    Label(folder.name, systemImage: "trash")
                                }
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

private struct PlayerScreen: View {
    var body: some View {
        ContentUnavailableView {
            Label("Player", systemImage: "waveform")
        } description: {
            Text("Phase 5b.2.e folgt")
        }
    }
}
