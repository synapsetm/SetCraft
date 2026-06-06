import Foundation
import Sparkle

/// Dünner Wrapper um Sparkles `SPUStandardUpdaterController`.
///
/// Sparkle erwartet, dass der Updater-Controller über die gesamte App-Lebenszeit
/// existiert (er hält die XPC-Verbindung und plant Hintergrund-Checks). Daher
/// halten wir hier eine einzelne Instanz, die in `SetCraftApp` als `@State`
/// instanziiert wird — und reichen den `updater` für den Menüeintrag durch.
///
/// Konfiguration kommt aus `Info.plist`:
/// - `SUFeedURL` — Adresse des Appcasts.
/// - `SUPublicEDKey` — EdDSA-Public-Key, gegen den der Updater jede Datei prüft.
/// - `SUEnableAutomaticChecks` / `SUScheduledCheckInterval` — Hintergrund-Checks.
@MainActor
final class UpdaterController {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
