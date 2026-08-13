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
    static var saveAllNow: (() -> Void)?

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.unsavedQuery?() == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Unsaved changes")
        alert.informativeText = String(localized: "There are library changes that haven't been written to the files yet. What would you like to do?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:    // Speichern
            Self.saveAllNow?()
            // Den Save-Tasks Zeit geben, dann wirklich beenden.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:   // Verwerfen
            return .terminateNow
        default:                          // Abbrechen
            return .terminateCancel
        }
    }
}
