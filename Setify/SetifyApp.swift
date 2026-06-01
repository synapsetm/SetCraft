import AppKit
import SwiftUI
import SetifyCore

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Pendant zu `colorScheme` auf der AppKit-Seite. SwiftUIs
    /// `.preferredColorScheme(nil)` updatet auf macOS Listen/Tables/Canvas-
    /// Subviews nicht zuverlässig zurück auf das System-Schema; durch
    /// gleichzeitiges Setzen von `NSApp.appearance` zwingen wir den ganzen
    /// AppKit-Baum nachzuziehen.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct SetifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var player: PlayerViewModel
    @State private var library: LibraryViewModel
    @State private var transport: TransportViewModel
    @State private var waveform: WaveformViewModel

    /// Sparkle-Updater. Lebt über die gesamte App-Lebenszeit, damit
    /// Hintergrund-Checks gemäss `SUScheduledCheckInterval` laufen können.
    @State private var updater = UpdaterController()

    @AppStorage("appearance") private var appearanceRaw: String = AppearancePreference.system.rawValue

    init() {
        // Appearance VOR der Fenstererzeugung setzen — sonst öffnet das erste
        // Window mit dem System-Schema, bevor unser Override greift.
        let storedAppearance = UserDefaults.standard.string(forKey: "appearance")
            ?? AppearancePreference.system.rawValue
        let initialPref = AppearancePreference(rawValue: storedAppearance) ?? .system
        NSApplication.shared.appearance = initialPref.nsAppearance

        // SQLite-Datei im macOS-Sandbox-Application-Support.
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let databaseURL = supportDir.appendingPathComponent("library.sqlite")

        let database: DatabaseService
        do {
            database = try DatabaseService(databaseURL: databaseURL)
        } catch {
            fatalError("Could not open SQLite database: \(error.localizedDescription)")
        }

        let p = PlayerViewModel()
        let lib = LibraryViewModel(
            repository: LibraryRepository(database: database),
            database: database
        )
        _player = State(initialValue: p)
        _library = State(initialValue: lib)
        _transport = State(initialValue: TransportViewModel(player: p))
        _waveform = State(initialValue: WaveformViewModel(database: database))
        AppDelegate.unsavedQuery = { [weak lib] in lib?.hasUnsavedChanges ?? false }
        AppDelegate.saveAllNow  = { [weak lib] in lib?.saveAllNow() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(player: player, library: library, transport: transport, waveform: waveform)
                .onOpenURL { url in
                    player.load(url: url)
                }
                // Bewusst KEIN `.preferredColorScheme(...)` — der SwiftUI-Modifier
                // schiebt das Schema in das Environment, hinterlässt aber bei
                // AppKit-Subviews (List, Table, Canvas) hängende Zustände, wenn
                // er von `.dark` → `nil` wechselt. `NSApp.appearance` plus
                // explizites Setzen pro Window löst das robust.
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearanceRaw) { _, _ in applyAppearance(appearance) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open audio file…") {
                    player.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Choose folder…") {
                    library.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                Picker("Appearance", selection: $appearanceRaw) {
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

    /// Setzt das NSApplication-Appearance UND zwingt jedes existierende Window,
    /// seine eigene `appearance`-Property nachzuziehen. Letzteres ist nötig,
    /// weil ein Window, das einmal explizit `.darkAqua` gesetzt bekam, sonst
    /// auf diesem Wert hängen bleibt — auch wenn `NSApp.appearance` danach
    /// auf `nil` (System folgen) zurückgesetzt wird.
    private func applyAppearance(_ pref: AppearancePreference) {
        let target = pref.nsAppearance
        NSApplication.shared.appearance = target
        for window in NSApplication.shared.windows {
            window.appearance = target
        }
    }
}
