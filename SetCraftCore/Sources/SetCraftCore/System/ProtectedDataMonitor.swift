import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Sagt, ob die Daten-Schutzklassen des Geräts gerade zugänglich sind — auf
/// iOS also: ob das iPhone entsperrt ist.
///
/// **Warum das ein eigener Dienst ist.** Bei gesperrtem Gerät kommt nicht nur
/// die App nicht mehr an geschützte Dateien; es kommt auch `smbclientd` nicht
/// mehr an die im Keychain liegenden Zugangsdaten des Shares. Genau das war
/// der Befund vom 2026-09-21 (Gerätelog):
///
/// ```
/// 14:37:10  smbclientd  idleTimerFired: entering idle-disconnect
/// 14:37:13  smbclientd  Error retrieving item … Code=-25308
/// 14:37:13  smbclientd  connectToServer: unable to obtain credentials
/// 14:37:15  kernel      lock state change unlocked (0)
/// 14:37:15  smbclientd  checkServerConnection: successfully connected
/// ```
///
/// `-25308` ist `errSecInteractionNotAllowed`. Die SMB-Session lässt sich bei
/// gesperrtem Gerät also **nicht neu aufbauen** — jeder Lese- und
/// Schreibzugriff auf die Quelle endet dann mit `errno 80` (EAUTH). Zwei
/// Stellen richten sich danach: der `PlayerStore` wiederholt einen daran
/// gescheiterten Load beim Entsperren, und der `TagLibTrackStore` verschiebt
/// Tag-Writes, statt sie in den nicht-atomaren In-place-Fallback laufen zu
/// lassen.
///
/// Auf macOS gibt es keine Entsprechung: dort meldet der Dienst dauerhaft
/// `true`, und die Handler feuern nie.
public final class ProtectedDataMonitor: @unchecked Sendable {

    public static let shared = ProtectedDataMonitor()

    private static let log = Logger(
        subsystem: "ch.buehler.beat.SetCraft", category: "ProtectedData"
    )

    private let lock = NSLock()
    private var available = true
    private var handlers: [@Sendable () -> Void] = []

    private init() {
        registerObservers()
    }

    /// Ob geschützte Daten gerade lesbar sind. Von jedem Thread abfragbar.
    ///
    /// Bis zum ersten `start()` und bis zur ersten Sperre lautet die Antwort
    /// `true` — also das Verhalten von vorher. Ein zu optimistisches `true`
    /// kostet höchstens einen Schreibversuch, der wie bisher scheitert; ein
    /// falsches `false` würde dagegen Writes grundlos aufschieben.
    public var isAvailable: Bool {
        lock.withLock { available }
    }

    /// Einmal beim App-Start rufen. Holt den Ausgangszustand, den die
    /// Notifications allein nicht liefern (sie melden nur Übergänge).
    @MainActor
    public func start() {
        #if canImport(UIKit) && !os(watchOS)
        update(to: UIApplication.shared.isProtectedDataAvailable)
        #endif
    }

    /// Registriert einen Handler, der beim Entsperren läuft. Aufruf auf dem
    /// Main-Thread; die Registrierung selbst ist von überall erlaubt.
    ///
    /// Bewusst ohne Abmelde-Token: die beiden Nutzer (`PlayerStore`,
    /// `LibraryStore`) leben so lange wie die App.
    public func onBecameAvailable(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { handlers.append(handler) }
    }

    // MARK: - Intern

    /// Eigene `nonisolated` Funktion, damit die Notification-Closures **nicht**
    /// die Isolation ihres Entstehungsorts erben. Ein MainActor-isoliertes,
    /// nicht-`@Sendable`-Callback, das Foundation woanders aufruft, beendet
    /// unter Swift 6 den Prozess mit `EXC_BREAKPOINT` — derselbe Stolperstein
    /// wie beim `MPMediaItemArtwork`-Handler.
    private nonisolated func registerObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        // `queue: .main` statt `nil`: UIKit postet diese beiden zwar ohnehin
        // auf dem Main-Thread, aber hier steht es dann schwarz auf weiss.
        center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.update(to: true)
        }
        center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.update(to: false)
        }
        #endif
    }

    private nonisolated func update(to newValue: Bool) {
        let (changed, toRun): (Bool, [@Sendable () -> Void]) = lock.withLock {
            guard available != newValue else { return (false, []) }
            available = newValue
            return (true, newValue ? handlers : [])
        }
        guard changed else { return }
        Self.log.notice("Geschützte Daten \(newValue ? "verfügbar" : "gesperrt", privacy: .public).")
        for handler in toRun { handler() }
    }
}
