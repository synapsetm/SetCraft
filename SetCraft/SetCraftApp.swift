import AppKit
import SwiftUI
import SetCraftCore

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

    @State private var showingDefaultPlayer = false

    init() {
        // Design B6 ist fest dunkel. Appearance VOR der Fenstererzeugung
        // setzen — sonst öffnet das erste Window mit dem System-Schema.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

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
        AppDelegate.saveAll = { [weak lib] in await lib?.saveAllNowAndWait() }
        AppDelegate.runningAnalysesQuery = { [weak lib] in lib?.pendingAnalysisCount ?? 0 }
    }

    var body: some Scene {
        // `Window` statt `WindowGroup`: SetCraft ist eine Ein-Fenster-App —
        // ein Player, eine Library, ein Satz ViewModels. Eine `WindowGroup`
        // legt für jede vom Finder gereichte Datei ein WEITERES Fenster an;
        // `Window` kann per Definition nur eine Instanz haben, das Open-Event
        // landet damit immer im bestehenden Fenster. Dass ⌘W/Fenster-Schliessen
        // hier die App beendet, ist erwünscht (siehe AppDelegate).
        Window("SetCraft", id: "main") {
            ContentView(player: player, library: library, transport: transport, waveform: waveform)
                // Datei-Open-Events kommen NICHT über `.onOpenURL`, sondern
                // über `AppDelegate.application(_:open:)` — sonst öffnet
                // SwiftUI für jede Datei ein zusätzliches Fenster dieser
                // WindowGroup. ContentView registriert dort seinen Handler.
                //
                // Bewusst KEIN `.preferredColorScheme(.dark)` — der SwiftUI-
                // Modifier hinterlässt bei AppKit-Subviews (List, Table, Canvas)
                // hängende Zustände. `NSApp.appearance` (siehe init) plus
                // explizites Setzen am Window ist der robuste Weg.
                .onAppear {
                    for window in NSApplication.shared.windows {
                        window.appearance = NSAppearance(named: .darkAqua)
                    }
                }
                .sheet(isPresented: $showingDefaultPlayer) { DefaultPlayerSheet() }
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

                Button("Set as Default Player…") {
                    showingDefaultPlayer = true
                }
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
