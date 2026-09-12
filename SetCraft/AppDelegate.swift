import AppKit
import SwiftUI

/// Liefert das `applicationShouldTerminate`-Hook in den SwiftUI-Lifecycle.
/// Zeigt bei offenen Änderungen einen Dialog mit Optionen:
///   - Speichern   → wartet bis alle Saves durch sind, dann beenden.
///   - Verwerfen   → beendet sofort.
///   - Abbrechen   → bleibt offen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wird in `SetCraftApp.init` gesetzt; gibt der App-Delegate Zugriff auf
    /// den aktuellen Speicher-Status der Library, ohne dass der Delegate
    /// die View-Modelle selbst kennen muss.
    static var unsavedQuery: (() -> Bool)?
    /// Schreibt alle offenen Änderungen und kehrt erst zurück, wenn sie auf
    /// der Platte sind — der Beenden-Ablauf wartet darauf.
    static var saveAll: (() async -> Void)?
    /// Wie viele Analysen gerade laufen. Sie tauchen in `unsavedQuery` nicht
    /// auf: dort steht ein Track erst, wenn sein Ergebnis schon vorliegt.
    static var runningAnalysesQuery: (() -> Int)?

    /// Obergrenze fürs Warten auf die Schreibvorgänge. Sicherheitsventil,
    /// damit ein hängender NAS-Mount das Beenden nicht dauerhaft blockiert.
    private static let saveBeforeQuitTimeout: TimeInterval = 15

    /// `NSApp.reply(toApplicationShouldTerminate:)` darf pro Beenden-Ablauf
    /// nur einmal ankommen — es können aber zwei Wege dorthin führen
    /// (Schreiben fertig, oder Sicherheitsventil).
    private var didReplyToTerminate = false

    /// `true`, solange der Beenden-Dialog läuft oder der Nutzer ihn gerade
    /// abgebrochen hat und das Hauptfenster noch nicht zurück ist.
    ///
    /// Hintergrund: `applicationShouldTerminateAfterLastWindowClosed` wird
    /// von AppKit **bei jedem** schliessenden Fenster geprüft — auch bei
    /// unserem eigenen modalen Dialog. Ist das Hauptfenster bereits zu, ist
    /// der Dialog das letzte Fenster: sein Schliessen löste sofort den
    /// nächsten Beenden-Versuch aus, der wieder den Dialog zeigte. Genau die
    /// Schleife, aus der man nicht mehr in die App zurückkam.
    private var isHandlingTerminationPrompt = false
    private var windowReturnObserver: NSObjectProtocol?

    // MARK: - Datei-Open-Events (Finder / Standard-Player)

    /// Wird von `ContentView.onAppear` gesetzt. Solange er `nil` ist, werden
    /// eintreffende URLs gepuffert — beim Kaltstart liefert AppKit das
    /// Open-Event, bevor die SwiftUI-Scene steht.
    private static var openFileHandler: ((URL) -> Void)?
    private static var pendingOpenURLs: [URL] = []

    static func setOpenFileHandler(_ handler: @escaping (URL) -> Void) {
        openFileHandler = handler
        let pending = pendingOpenURLs
        pendingOpenURLs = []
        for url in pending { handler(url) }
    }

    /// KRITISCH für das Ein-Fenster-Verhalten: implementiert der App-Delegate
    /// diese Methode, übernimmt er das Open-Event vollständig. Ohne sie
    /// behandelt SwiftUI jede vom Finder gereichte Datei wie ein eigenes
    /// Dokument und öffnet dafür ein **weiteres** Fenster der `WindowGroup`.
    /// Deshalb läuft das Öffnen hier durch — und **nicht** über `.onOpenURL`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            if let handler = Self.openFileHandler {
                handler(url)
            } else {
                Self.pendingOpenURLs.append(url)
            }
        }
        activateExistingWindow()
    }

    /// Dock-Klick ohne sichtbares Fenster: bestehendes Fenster wieder
    /// hervorholen, statt SwiftUI ein neues erzeugen zu lassen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { activateExistingWindow() }
        return true
    }

    /// Holt das bestehende Hauptfenster nach vorn. Beim Kaltstart existiert es
    /// noch nicht — dann macht SwiftUI ohnehin genau eines auf.
    private func activateExistingWindow() {
        // Läuft gerade ein modales Panel (z. B. unser eigener Quellen-Picker,
        // ausgelöst durch eine kurz zuvor geöffnete Datei), darf das Fenster
        // NICHT nach vorn — sonst verdeckt es den Dialog, auf den die App
        // wartet.
        guard NSApp.modalWindow == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.canBecomeMain && !$0.isMiniaturized }
            ?? NSApp.windows.first { $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // System-Tab-Bar deaktivieren — wir nutzen keine Tabs, und der
        // Menüpunkt „Show Tab Bar" hätte sonst keinen Effekt für den Nutzer.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// SetCraft hat genau ein Fenster — ist es zu, gibt es nichts mehr zu
    /// bedienen (und der Track liefe unsichtbar weiter). Also mit dem Fenster
    /// auch die App beenden. AppKits Default ist `false`, gedacht für Apps mit
    /// mehreren/wiederöffenbaren Dokumentfenstern.
    /// Der Weg führt weiter über `applicationShouldTerminate` — offene
    /// Tag-Änderungen bekommen ihren Speichern-Dialog also weiterhin.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Nicht, während unser eigener Beenden-Dialog im Spiel ist — siehe
        // `isHandlingTerminationPrompt`. ⌘Q bleibt davon unberührt, das geht
        // direkt über `applicationShouldTerminate`.
        !isHandlingTerminationPrompt
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasUnsaved = Self.unsavedQuery?() == true
        let runningAnalyses = Self.runningAnalysesQuery?() ?? 0
        guard hasUnsaved || runningAnalyses > 0 else { return .terminateNow }
        isHandlingTerminationPrompt = true

        // Laufende Analysen sterben mit dem Prozess, und ihr Ergebnis ist
        // dann weg — die Datei wird ja erst am Ende geschrieben. Also
        // wenigstens sagen, was verloren geht.
        let analysisNote = runningAnalyses > 0
            ? String(localized: "\(runningAnalyses) analyses are still running. Quitting now discards their results.")
            : nil

        let alert = NSAlert()
        alert.alertStyle = .warning

        guard hasUnsaved else {
            // Nur Analysen offen: hier gibt es nichts zu speichern, nur die
            // Entscheidung, ob die Rechenarbeit verfallen darf.
            alert.messageText = String(localized: "Analyses still running")
            alert.informativeText = analysisNote ?? ""
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateNow
            }
            restoreClosedWindow()
            return .terminateCancel
        }

        alert.messageText = String(localized: "Unsaved changes")
        let unsavedText = String(localized: "There are library changes that haven't been written to the files yet. What would you like to do?")
        alert.informativeText = [unsavedText, analysisNote]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:    // Speichern
            saveThenTerminate()
            return .terminateLater
        case .alertSecondButtonReturn:   // Verwerfen
            return .terminateNow
        default:                          // Abbrechen
            // Kam die Beendigung vom Schliessen des letzten Fensters, ist das
            // Fenster an dieser Stelle bereits zu. Ohne das Zurückholen bliebe
            // eine unsichtbare App zurück — inklusive weiterlaufendem Track.
            restoreClosedWindow()
            return .terminateCancel
        }
    }

    /// Schreibt alles raus und beendet erst dann. Früher wurde hier pauschal
    /// 1,5 Sekunden gewartet und danach gehofft — auf einem NAS oder bei
    /// vielen Dateien reichte das nicht, und bestätigte Änderungen gingen
    /// beim Beenden verloren.
    private func saveThenTerminate() {
        Task { @MainActor in
            await Self.saveAll?()
            self.replyToTerminateOnce()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveBeforeQuitTimeout) { [weak self] in
            self?.replyToTerminateOnce()
        }
    }

    private func replyToTerminateOnce() {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Holt das bereits geschlossene Hauptfenster zurück, indem die App sich
    /// selbst „nochmal öffnet" — dasselbe Reopen-Ereignis wie beim Dock-Klick.
    /// Nur so entsteht wieder ein echtes SwiftUI-Fenster: das geschlossene
    /// NSWindow direkt per `makeKeyAndOrderFront` hervorzuholen liefert bloss
    /// eine leere Hülle ohne Inhalt (getestet).
    /// Muss aus dem Terminate-Callback heraus verzögert laufen, sonst kommt
    /// das Reopen an, während AppKit noch im Beenden-Ablauf steckt.
    private func restoreClosedWindow() {
        guard !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) else {
            // Fenster war die ganze Zeit da (⌘Q-Weg) — nichts zu tun.
            isHandlingTerminationPrompt = false
            return
        }
        clearTerminationGuardWhenWindowReturns()
        DispatchQueue.main.async {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    /// Löst die Sperre, sobald wieder ein Hauptfenster da ist. Bleibt sie
    /// hängen (Fenster kommt nicht zurück), beendet höchstens ⌘Q die App —
    /// besser als eine Schleife, aus der es keinen Ausweg gibt.
    private func clearTerminationGuardWhenWindowReturns() {
        if let existing = windowReturnObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        windowReturnObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHandlingTerminationPrompt = false
                if let token = self.windowReturnObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.windowReturnObserver = nil
                }
            }
        }
    }
}
