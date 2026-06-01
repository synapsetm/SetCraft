import AppKit
import SwiftUI

/// Liefert das `applicationShouldTerminate`-Hook in den SwiftUI-Lifecycle.
/// Zeigt bei offenen Änderungen einen Dialog mit Optionen:
///   - Speichern   → wartet bis alle Saves durch sind, dann beenden.
///   - Verwerfen   → beendet sofort.
///   - Abbrechen   → bleibt offen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wird in `SetifyApp.init` gesetzt; gibt der App-Delegate Zugriff auf
    /// den aktuellen Speicher-Status der Library, ohne dass der Delegate
    /// die View-Modelle selbst kennen muss.
    static var unsavedQuery: (() -> Bool)?
    static var saveAllNow: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.unsavedQuery?() == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Ungespeicherte Änderungen"
        alert.informativeText = "Es gibt Bibliotheks-Änderungen, die noch nicht in die Dateien geschrieben wurden. Was möchtest du tun?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Verwerfen")
        alert.addButton(withTitle: "Abbrechen")

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
