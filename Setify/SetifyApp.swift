import SwiftUI

@main
struct SetifyApp: App {
    @State private var player = PlayerViewModel()
    @State private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(player: player, library: library)
                .onOpenURL { url in
                    player.load(url: url)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Audiodatei öffnen…") {
                    player.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Ordner wählen…") {
                    library.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
