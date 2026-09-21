import Foundation
import OSLog

/// Hält die Verbindung zur Quelle warm, solange aus ihr gespielt wird.
///
/// **Wogegen das hilft.** `smbclientd` trennt eine SMB-Session nach rund zwei
/// Minuten Leerlauf von selbst (am Gerät gemessen: 2:09, 2:01, 2:0x zwischen
/// letztem Zugriff und `idleTimerFired`). Der Wiederaufbau braucht die
/// Zugangsdaten aus dem Keychain — und die sind bei **gesperrtem** iPhone
/// nicht lesbar (`errSecInteractionNotAllowed`). Ab dann liefert der Share
/// gar nichts mehr, bis jemand das Gerät entsperrt.
///
/// Genau diese Lücke entsteht im Normalbetrieb: ein Track läuft sechs
/// Minuten, die Vorausschau ist nach einer Minute fertig, die restlichen fünf
/// Minuten ist die Session leer — und fällt in den Idle-Disconnect. Sperrt
/// der Nutzer zwischendurch den Bildschirm, ist der Share tot, und die
/// Wiedergabe reicht nur noch so weit wie die Kopien im `PlaybackCache`
/// (am 2026-09-21 rund 20 Minuten, dann Abbruch).
///
/// **Was es tut.** Einmal pro Minute eine Attribut-Abfrage auf die laufende
/// Datei. Das ist derselbe `getattrlist`, den der FileProvider ohnehin
/// ständig macht — er geht durch bis zur SMB-Session und setzt deren
/// Idle-Timer zurück. Kosten: ein paar hundert Bytes pro Minute.
///
/// **Was es nicht kann.** Stirbt die TCP-Verbindung selbst (Mobilfunk-Handover,
/// VPN-Wechsel — im Log zweimal passiert), braucht auch dieser Reconnect den
/// Keychain und scheitert bei gesperrtem Gerät. Der `PlaybackCache` bleibt
/// das letzte Netz.
public final class SourceKeepAlive: @unchecked Sendable {

    public static let shared = SourceKeepAlive()

    private static let log = Logger(
        subsystem: "ch.buehler.beat.SetCraft", category: "SourceKeepAlive"
    )

    /// Eigene Queue, nicht der Cooperative Pool: die Abfrage geht zum
    /// FileProvider und blockiert dort im Zweifel sekundenlang.
    private let queue = DispatchQueue(
        label: "ch.buehler.beat.SetCraft.source-keepalive",
        qos: .utility
    )

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var target: URL?
    /// Ergebnis der letzten Abfrage — nur Wechsel werden geloggt, sonst
    /// stünde im Gerätelog minütlich dieselbe Zeile.
    private var lastReachable: Bool?

    /// Abstand zwischen zwei Abfragen. Deutlich unter den ~2 Minuten, nach
    /// denen `smbclientd` die Session fallen lässt.
    private static let interval: TimeInterval = 60

    private init() {}

    /// Beginnt (oder verlegt) die Wach-Abfrage auf diese Datei.
    ///
    /// Bei einer Quelle, die ohnehin lokal liegt, passiert nichts — es gibt
    /// keine Session, die einschlafen könnte. Dieselbe Unterscheidung wie im
    /// `PlaybackCache`, und aus demselben Grund.
    public func start(for source: URL) {
        guard PlaybackCache.shared.shouldCache(source) else {
            stop()
            return
        }

        // Anlegen und Eintragen unter demselben Lock: zwei Aufrufer dürfen
        // nicht beide „kein Timer da" sehen und je einen starten — der
        // zweite wäre nirgends mehr vermerkt und tickte bis zum App-Ende
        // weiter.
        let created: DispatchSourceTimer? = lock.withLock {
            target = source
            lastReachable = nil
            guard timer == nil else { return nil }

            let fresh = DispatchSource.makeTimerSource(queue: queue)
            fresh.schedule(
                deadline: .now() + Self.interval,
                repeating: Self.interval,
                leeway: .seconds(10)
            )
            // Der Handler läuft auf `queue` — seriell. Blockiert eine Abfrage
            // länger als das Intervall, fallen die verpassten Feuerungen
            // zusammen, statt sich aufzustauen.
            fresh.setEventHandler { [weak self] in self?.tick() }
            timer = fresh
            return fresh
        }
        // `resume()` ausserhalb des Locks — der Handler nimmt ihn selbst.
        created?.resume()
    }

    /// Hält die Abfrage an. Idempotent.
    public func stop() {
        let running: DispatchSourceTimer? = lock.withLock {
            let existing = timer
            timer = nil
            target = nil
            lastReachable = nil
            return existing
        }
        running?.cancel()
    }

    private func tick() {
        guard let url = lock.withLock({ target }) else { return }

        let started = Date()
        let reachable = (try? url.resourceValues(forKeys: [.fileSizeKey])) != nil
        let elapsed = Date().timeIntervalSince(started)

        let changed: Bool = lock.withLock {
            guard lastReachable != reachable else { return false }
            lastReachable = reachable
            return true
        }
        guard changed else { return }

        if reachable {
            Self.log.notice("""
                Quelle erreichbar: \(url.lastPathComponent, privacy: .public) \
                (\(String(format: "%.1f", elapsed), privacy: .public)s)
                """)
        } else {
            Self.log.error("""
                Quelle antwortet nicht: \(url.lastPathComponent, privacy: .public) \
                (\(String(format: "%.1f", elapsed), privacy: .public)s) — \
                Session vermutlich getrennt und bei gesperrtem Gerät nicht neu aufbaubar.
                """)
        }
    }
}
