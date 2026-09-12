import Foundation

/// Ein offener Security-Scoped Zugriff auf eine Quelle (Ordner oder Einzel-
/// datei) — mit Referenzzählung.
///
/// Hintergrund: Ein Quellenwechsel schliesst den Scope der alten Quelle
/// sofort. Analysen und Tag-Writes, die zu diesem Zeitpunkt noch laufen,
/// verlieren dadurch **mitten in der Operation** den Dateizugriff. Typisches
/// Schadensbild ist ein `copyItem`, das noch durchgeht, und ein `moveItem`
/// wenige Millisekunden später, das mit `EPERM` scheitert — die Analyse ist
/// dann zwar gerechnet, landet aber nie im Tag.
///
/// Deshalb zählt dieser Typ seine Nutzer: `requestRelease()` meldet den Scope
/// nur zur Freigabe an, geschlossen wird er erst, wenn das letzte `Token`
/// zurückgegeben ist.
///
/// Thread-sicher über einen internen Lock, damit `Token.deinit` aus jedem
/// Kontext freigeben kann.
public final class SecurityScope: @unchecked Sendable {

    public let url: URL

    /// `false`, wenn das System den Zugriff verweigert hat (verlorenes TCC-
    /// Recht nach Reinstall/Signaturwechsel) **oder** die URL gar nicht
    /// security-scoped ist — letzteres ist der Normalfall für URLs aus
    /// `NSOpenPanel`, die auch ohne Scope zugreifbar bleiben.
    public let didStartAccess: Bool

    private let lock = NSLock()
    private let stopAccess: @Sendable (URL) -> Void
    private var users = 0
    private var releaseRequested = false
    private var isOpen: Bool

    public convenience init(url: URL) {
        self.init(
            url: url,
            startAccess: { $0.startAccessingSecurityScopedResource() },
            stopAccess: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    /// Testbarer Einstieg: `startAccessingSecurityScopedResource()` liefert für
    /// gewöhnliche Datei-URLs immer `false`, damit wäre die Zählung sonst nicht
    /// prüfbar.
    init(
        url: URL,
        startAccess: @Sendable (URL) -> Bool,
        stopAccess: @escaping @Sendable (URL) -> Void
    ) {
        self.url = url
        self.stopAccess = stopAccess
        self.didStartAccess = startAccess(url)
        self.isOpen = didStartAccess
    }

    /// `true`, solange der Scope noch offen ist — also weder freigegeben noch
    /// nie zustande gekommen.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    /// Nimmt den Scope in Beschlag. Solange das Token lebt, bleibt der Zugriff
    /// offen, auch wenn zwischenzeitlich die Quelle gewechselt wurde.
    /// `nil`, wenn der Scope bereits geschlossen ist oder nie geöffnet wurde.
    public func acquire() -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return nil }
        users += 1
        return Token(owner: self)
    }

    /// Meldet den Scope zur Freigabe an. Geschlossen wird er sofort, wenn
    /// gerade niemand darauf arbeitet — sonst beim Rückgeben des letzten
    /// Tokens.
    public func requestRelease() {
        lock.lock()
        releaseRequested = true
        let shouldClose = isOpen && users == 0
        if shouldClose { isOpen = false }
        lock.unlock()
        if shouldClose { stopAccess(url) }
    }

    fileprivate func release() {
        lock.lock()
        users -= 1
        let shouldClose = isOpen && releaseRequested && users == 0
        if shouldClose { isOpen = false }
        lock.unlock()
        if shouldClose { stopAccess(url) }
    }

    /// Anspruch auf einen offenen Scope. Freigabe ist idempotent; wer das
    /// Token einfach fallen lässt, gibt es über `deinit` frei.
    /// `@unchecked Sendable`, weil der Zustand ausschliesslich unter `lock`
    /// steht — Tokens wandern in `Task.detached`-Closures.
    public final class Token: @unchecked Sendable {
        private let owner: SecurityScope
        private let lock = NSLock()
        private var released = false

        /// Quelle, die dieses Token offen hält — für Diagnose und Tests.
        public var scopeURL: URL { owner.url }

        fileprivate init(owner: SecurityScope) {
            self.owner = owner
        }

        public func release() {
            lock.lock()
            let isFirst = !released
            released = true
            lock.unlock()
            if isFirst { owner.release() }
        }

        deinit { release() }
    }
}

/// Verwaltet den Scope der aktiven Quelle und hält beim Wechsel jene Scopes
/// am Leben, auf denen noch Arbeit läuft.
///
/// `token(for:)` ordnet eine Datei dem Scope zu, der sie abdeckt — auch einem
/// bereits abgemeldeten. Genau das braucht ein Tag-Write, der zu einer
/// Analyse aus der vorherigen Quelle gehört.
public final class SecurityScopeRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private let makeScope: @Sendable (URL) -> SecurityScope
    private var active: SecurityScope?
    /// Abgemeldete Scopes, die noch mindestens ein Token halten.
    private var retiring: [SecurityScope] = []

    public convenience init() {
        self.init(makeScope: { SecurityScope(url: $0) })
    }

    /// Testbarer Einstieg — siehe `SecurityScope.init(url:startAccess:stopAccess:)`.
    init(makeScope: @escaping @Sendable (URL) -> SecurityScope) {
        self.makeScope = makeScope
    }

    public var activeURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return active?.url
    }

    /// Öffnet den Scope für `url` und macht ihn zur aktiven Quelle; der
    /// bisherige wird zur Freigabe angemeldet.
    ///
    /// - Parameter requireScope: `true` für URLs aus aufgelösten Bookmarks —
    ///   scheitert `startAccessingSecurityScopedResource()`, ist der Zugriff
    ///   verloren, es wird nichts umgestellt und `false` zurückgegeben.
    ///   `false` für URLs aus `NSOpenPanel`, die ohne Scope zugreifbar sind.
    @discardableResult
    public func activate(_ url: URL, requireScope: Bool = true) -> Bool {
        let scope = makeScope(url)
        guard scope.didStartAccess || !requireScope else { return false }

        lock.lock()
        let previous = active
        active = scope
        if let previous {
            retiring.append(previous)
        }
        lock.unlock()

        previous?.requestRelease()
        pruneClosedScopes()
        return true
    }

    /// Meldet die aktive Quelle ab. Laufende Operationen behalten ihren
    /// Zugriff, bis sie ihr Token zurückgeben.
    public func deactivate() {
        lock.lock()
        let previous = active
        active = nil
        if let previous {
            retiring.append(previous)
        }
        lock.unlock()

        previous?.requestRelease()
        pruneClosedScopes()
    }

    /// Gibt alle Scopes frei — für `deinit` des besitzenden ViewModels.
    public func releaseAll() {
        lock.lock()
        let all = ([active].compactMap { $0 }) + retiring
        active = nil
        retiring.removeAll()
        lock.unlock()

        for scope in all { scope.requestRelease() }
    }

    /// Token für eine konkrete Datei: sucht den Scope, der sie abdeckt, und
    /// hält ihn offen, bis das Token zurückgegeben wird. `nil`, wenn kein
    /// passender Scope (mehr) offen ist — dann verhält sich der Aufrufer wie
    /// bisher und der Zugriff scheitert oder gelingt ohne unser Zutun.
    public func token(for fileURL: URL) -> SecurityScope.Token? {
        pruneClosedScopes()

        lock.lock()
        let candidates = ([active].compactMap { $0 }) + retiring
        lock.unlock()

        let path = fileURL.standardizedFileURL.path
        // Längster Treffer zuerst: verschachtelte Quellen (Ordner + Unter-
        // ordner beide als Quelle hinzugefügt) sollen den spezifischeren
        // Scope bekommen.
        let covering = candidates
            .filter { Self.scope($0, covers: path) }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
        return covering?.acquire()
    }

    /// Token für die aktive Quelle selbst — für Arbeit, die nicht an einer
    /// einzelnen Datei hängt (Scan, Ordner-Operationen).
    public func tokenForActiveSource() -> SecurityScope.Token? {
        lock.lock()
        let scope = active
        lock.unlock()
        return scope?.acquire()
    }

    private static func scope(_ scope: SecurityScope, covers path: String) -> Bool {
        let base = scope.url.standardizedFileURL.path
        if path == base { return true }
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func pruneClosedScopes() {
        lock.lock()
        retiring.removeAll { !$0.isActive }
        lock.unlock()
    }

    deinit {
        // Kein Lock nötig: deinit läuft, wenn niemand mehr referenziert.
        active?.requestRelease()
        for scope in retiring { scope.requestRelease() }
    }
}
