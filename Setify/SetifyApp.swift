import SwiftUI

@main
struct SetifyApp: App {
    @State private var player: PlayerViewModel
    @State private var library: LibraryViewModel
    @State private var transport: TransportViewModel

    init() {
        let p = PlayerViewModel()
        _player = State(initialValue: p)
        _library = State(initialValue: LibraryViewModel())
        _transport = State(initialValue: TransportViewModel(player: p))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(player: player, library: library, transport: transport)
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
