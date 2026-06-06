import AppKit
import SwiftUI
import SetCraftCore

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
struct SetCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var player: PlayerViewModel
    @State private var library: LibraryViewModel
    @State private var transport: TransportViewModel
    @State private var waveform: WaveformViewModel

    /// Sparkle-Updater. Lebt über die gesamte App-Lebenszeit, damit
    /// Hintergrund-Checks gemäss `SUScheduledCheckInterval` laufen können.
    @State private var updater = UpdaterController()

    @AppStorage("appearance") private var appearanceRaw: String = AppearancePreference.dark.rawValue

    init() {
        // Appearance VOR der Fenstererzeugung setzen — sonst öffnet das erste
        // Window mit dem System-Schema, bevor unser Override greift.
        let storedAppearance = UserDefaults.standard.string(forKey: "appearance")
            ?? AppearancePreference.dark.rawValue
        let initialPref = AppearancePreference(rawValue: storedAppearance) ?? .dark
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

        // Ein gemeinsamer Waveform-Cache, geteilt zwischen Library (Prefetch
        // beim Analyze-Trigger) und WaveformViewModel (Anzeige des aktiven
        // Tracks). Memory-Cache + DB-Cache landen so an einer Stelle.
        let waveformCache = WaveformCache(database: database)

        let p = PlayerViewModel()
        let lib = LibraryViewModel(
            repository: LibraryRepository(database: database),
            database: database,
            waveformCache: waveformCache
        )
        _player = State(initialValue: p)
        _library = State(initialValue: lib)
        _transport = State(initialValue: TransportViewModel(player: p))
        _waveform = State(initialValue: WaveformViewModel(cache: waveformCache))
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
            CommandGroup(replacing: .appInfo) {
                Button("About SetCraft") {
                    showAboutPanel()
                }
            }
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

    /// Eigenes About-Fenster mit Lizenz- und Quell-Hinweisen für die genutzten
    /// Open-Source-Bibliotheken. GPLv3 (aubio, libKeyFinder), GPLv2 (FFTW)
    /// verlangen, dass auf die korrespondierende Quelle hingewiesen wird;
    /// LGPL/MIT/BSL verlangen Copyright + Lizenz-Nennung. Der GitHub-Link am
    /// Ende deckt §6 GPLv3 ab.
    private func showAboutPanel() {
        let credits = NSMutableAttributedString()
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let headAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]

        func add(_ s: String, _ attrs: [NSAttributedString.Key: Any] = bodyAttrs) {
            credits.append(NSAttributedString(string: s, attributes: attrs))
        }

        add("SetCraft uses the following open-source libraries:\n\n")

        add("aubio (GPLv3)\n", headAttrs)
        add("© The aubio Team — https://aubio.org\n\n")

        add("libKeyFinder (GPLv3)\n", headAttrs)
        add("© Ibrahim Sha’ath — https://github.com/mixxxdj/libKeyFinder\n\n")

        add("FFTW (GPLv2+)\n", headAttrs)
        add("© Matteo Frigo, Massachusetts Institute of Technology — https://www.fftw.org\n\n")

        add("TagLib (LGPLv2.1 / MPL)\n", headAttrs)
        add("© Scott Wheeler et al. — https://taglib.org\n\n")

        add("utfcpp (Boost Software License 1.0)\n", headAttrs)
        add("© Nemanja Trifunovic\n\n")

        add("Sparkle (MIT)\n", headAttrs)
        add("© Andy Matuschak and the Sparkle project — https://sparkle-project.org\n\n")

        add("GRDB.swift (MIT)\n", headAttrs)
        add("© Gwendal Roué — https://github.com/groue/GRDB.swift\n\n")

        add(
            "Per GPL §6 the complete corresponding source — including the " +
            "build scripts that produced the bundled aubio, libKeyFinder and " +
            "FFTW binaries — is available at:\nhttps://github.com/synapsetm/SetCraft\n",
            bodyAttrs
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.credits: credits
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
