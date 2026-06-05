//
//  SetCraft_iOSApp.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 03.06.2026.
//

import SwiftUI

@main
struct SetCraft_iOSApp: App {
    @State private var bootstrap = AppBootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(
                libraryStore: bootstrap.libraryStore,
                playerStore: bootstrap.playerStore
            )
            .preferredColorScheme(.dark)
        }
        // Beim Backgrounding den Save-Queue (vom Active-Track-Guard
        // abgelehnte Tag-Edits) zwangsschreiben — iOS kann uns danach
        // jederzeit suspendieren oder beenden. Sicheres Schreiben über
        // `force: true` ist OK, weil `replaceItemAt` atomar inode-swappt.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                let store = bootstrap.libraryStore
                Task { await store.flushPendingSaves() }
            }
        }
    }
}
