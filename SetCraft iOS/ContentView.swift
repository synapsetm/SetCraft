//
//  ContentView.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 03.06.2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryScreen()
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
    var body: some View {
        ContentUnavailableView(
            "Library",
            systemImage: "list.bullet",
            description: Text("Phase 5b.2.d folgt")
        )
    }
}

private struct PlayerScreen: View {
    var body: some View {
        ContentUnavailableView(
            "Player",
            systemImage: "waveform",
            description: Text("Phase 5b.2.e folgt")
        )
    }
}

#Preview {
    ContentView()
}
