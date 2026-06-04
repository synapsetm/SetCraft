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

    var body: some Scene {
        WindowGroup {
            ContentView(
                libraryStore: bootstrap.libraryStore,
                playerStore: bootstrap.playerStore
            )
            .preferredColorScheme(.dark)
        }
    }
}
