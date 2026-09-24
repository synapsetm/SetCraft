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
/// **Was es tut.** Einmal pro Minute ein **echter Lesezugriff** auf die
/// laufende Datei: `open`, ein Byte von wechselndem Offset, `close` — der
/// Handle mit `F_NOCACHE`, damit die Seite nicht aus dem UBC beantwortet
/// wird. Kosten: ein Byte pro Minute plus den Protokoll-Overhead.
///
/// **Warum nicht mehr `resourceValues`.** Genau das stand hier bis Build 34,
/// mit der Annahme, es sei „derselbe `getattrlist`, den der FileProvider
/// ohnehin macht". Das Gerätelog vom 2026-09-21 widerlegt sie: neun Ticks
/// meldeten „Quelle erreichbar (0.0s)" — auch in den Fenstern, in denen der
/// Share nachweislich tot war (`-25308` bei jedem Track-Wechsel), und
/// `idleTimerFired` kam im selben Set **fünfmal**. Die Attribut-Abfrage wird
/// aus dem Metadaten-Cache des FileProviders beantwortet und erreicht die
/// SMB-Session nie. Die 0.0s waren das Indiz, der Idle-Disconnect der Beweis.
///
/// **Woran sich der Erfolg ablesen lässt.** Nicht am Rückgabewert dieser
/// Klasse, sondern am Gerätelog: taucht während eines Sets noch
/// `smbclientd: idleTimerFired` auf, erreicht auch dieser Aufruf den Server
/// nicht und der nächste Kandidat ist eine Verzeichnis-Enumeration. Damit
/// sich das überhaupt gegenprüfen lässt, steht **jeder** Tick im Log, nicht
/// nur der Wechsel — eine Zeile pro Minute, rund fünfzig pro Set.
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
    /// Zähler der Ticks für diese Datei. Dient nur dazu, den Lese-Offset
    /// wandern zu lassen — zweimal dieselbe Stelle käme aus dem Cache des
    /// Providers, und genau das ist der Fehler, den diese Klasse gerade
    /// hinter sich hat.
    private var probeCount = 0

    /// Abstand zwischen zwei Abfragen. Deutlich unter den ~2 Minuten, nach
    /// denen `smbclientd` die Session fallen lässt.
    private static let interval: TimeInterval = 60

    /// Fenster, über das der Lese-Offset wandert. Klein genug, dass jede
    /// Musikdatei es abdeckt, gross genug, dass sich die Seiten nicht
    /// wiederholen.
    private static let probeWindow: UInt64 = 1 << 20

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
            probeCount = 0
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
            probeCount = 0
            return existing
        }
        running?.cancel()
    }

    private func tick() {
        let url: URL
        let offsetSeed: Int
        switch lock.withLock({ () -> (URL, Int)? in
            guard let target else { return nil }
            probeCount += 1
            return (target, probeCount)
        }) {
        case .none:
            return
        case .some(let pair):
            (url, offsetSeed) = pair
        }

        let started = Date()
        let result = read(oneByteOf: url, seed: offsetSeed)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        let name = url.lastPathComponent

        switch result {
        case .success:
            Self.log.notice("""
                Wach-Lesezugriff ok: \(name, privacy: .public) (\(elapsed, privacy: .public)s)
                """)
        case .failure(let error):
            Self.log.error("""
                Wach-Lesezugriff gescheitert: \(name, privacy: .public) \
                (\(elapsed, privacy: .public)s) — \(error.localizedDescription, privacy: .public). \
                Session vermutlich getrennt und bei gesperrtem Gerät nicht neu aufbaubar.
                """)
        }
    }

    /// Ein Byte von einer wandernden Stelle der Datei — der eigentliche
    /// Wach-Impuls.
    ///
    /// Vier Details, die hier keine Kosmetik sind:
    ///
    /// - **`open`, nicht `stat`.** Erst der Open löst beim LiveFS-Provider den
    ///   `LIAccessCheck` aus, und der prüft die Server-Verbindung. Ein `stat`
    ///   wird aus dem Metadaten-Cache bedient und merkt nichts.
    /// - **`F_NOCACHE`.** Ohne das beantwortet der Unified Buffer Cache die
    ///   Leseanforderung aus dem RAM, sobald die Seite einmal drin war.
    /// - **Wandernder Offset.** Damit nicht jeder Tick auf derselben Seite
    ///   landet, die der Provider längst lokal hat.
    /// - **Keine Grössenabfrage.** Hier stand bis 2026-09-24 ein
    ///   `resourceValues(forKeys: [.fileSizeKey])`, um den Offset zu
    ///   begrenzen. Das ist derselbe Attribut-Pfad, dem diese Klasse gerade
    ///   entkommen ist, und im Gerätelog vom 24.09. ist er als einziger
    ///   Aufruf nachweisbar in den Keychain-Fehler gelaufen (Tick 17:11:27.068,
    ///   0.4 s, `getAttr … checkServerConnection error: 80` 6 ms nach dessen
    ///   Ende) — während `open` und `read` durchkamen. Der Offset wandert
    ///   stattdessen in einem festen Fenster; liegt er hinter dem Dateiende,
    ///   liefert der `read` null Bytes, und auch das ist ein erfolgreicher
    ///   Round-Trip zum Server.
    private func read(oneByteOf url: URL, seed: Int) -> Result<Void, Error> {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .failure(error)
        }
        defer { try? handle.close() }

        // Rückgabewert bewusst ignoriert: schlägt F_NOCACHE fehl, ist der
        // Lesezugriff immer noch besser als die frühere Attribut-Abfrage.
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

        do {
            // Goldener-Schnitt-Schritt über ein Fenster, das jede Musikdatei
            // sicher abdeckt (1 MiB): wandert, ohne sich früh zu wiederholen,
            // und braucht weder Zufallsgenerator noch Dateigrösse.
            // Unsigned gerechnet: `&*` darf überlaufen, ein negatives
            // Zwischenergebnis wäre beim Offset ein Absturz.
            let offset = (UInt64(truncatingIfNeeded: seed) &* 2_654_435_761)
                % Self.probeWindow
            try handle.seek(toOffset: offset)
            _ = try handle.read(upToCount: 1)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
