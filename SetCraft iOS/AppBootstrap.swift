//
//  AppBootstrap.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 03.06.2026.
//

import Foundation
import SetCraftCore

/// Hält alle App-weiten Services. Einmal in App.init() erstellt und via @State
/// in der App-Struct gehalten, dann an Views durchgereicht. Pendant zum
/// init()-Block in der Mac-`SetCraftApp`.
@MainActor
final class AppBootstrap {
    let database: DatabaseService
    let repository: LibraryRepository
    let libraryStore: LibraryStore
    let audioSession: AudioSessionManager
    let waveformCache: WaveformCache
    let playerStore: PlayerStore
    let nowPlayingManager: NowPlayingManager

    init() {
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let databaseURL = supportDir.appendingPathComponent("library.sqlite")

        do {
            self.database = try DatabaseService(databaseURL: databaseURL)
        } catch {
            fatalError("Could not open SQLite database: \(error.localizedDescription)")
        }

        self.repository = LibraryRepository(database: database)
        self.libraryStore = LibraryStore(database: database, repository: repository)
        self.audioSession = AudioSessionManager()
        self.waveformCache = WaveformCache(database: database)
        self.playerStore = PlayerStore(
            library: libraryStore,
            session: audioSession,
            waveformCache: waveformCache
        )

        // NowPlayingManager braucht den PlayerStore — und umgekehrt:
        // PlayerStore.nowPlaying wird nachträglich gesetzt, damit
        // Zustandsänderungen den Lock-Screen aktualisieren.
        self.nowPlayingManager = NowPlayingManager(player: playerStore)
        self.playerStore.nowPlaying = nowPlayingManager
    }
}
