import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Hell"
        case .dark:   return "Dunkel"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@main
struct SetifyApp: App {
    @State private var player: PlayerViewModel
    @State private var library: LibraryViewModel
    @State private var transport: TransportViewModel
    @State private var waveform: WaveformViewModel

    @AppStorage("appearance") private var appearanceRaw: String = AppearancePreference.system.rawValue

    init() {
        let p = PlayerViewModel()
        _player = State(initialValue: p)
        _library = State(initialValue: LibraryViewModel())
        _transport = State(initialValue: TransportViewModel(player: p))
        _waveform = State(initialValue: WaveformViewModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(player: player, library: library, transport: transport, waveform: waveform)
                .onOpenURL { url in
                    player.load(url: url)
                }
                .preferredColorScheme(appearance.colorScheme)
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
            CommandMenu("Ansicht") {
                Picker("Erscheinungsbild", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            }
        }
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }
}
