import SwiftUI

@main
struct SetifyApp: App {
    @State private var viewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    viewModel.load(url: url)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Audiodatei öffnen…") {
                    viewModel.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
