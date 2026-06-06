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
