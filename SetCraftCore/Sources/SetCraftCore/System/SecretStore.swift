import Foundation
import OSLog
import Security

/// Ablage für kleine Geheimnisse (Tokens), die nicht in `UserDefaults`
/// gehören. Als Protokoll, damit die Migration ohne echten Keychain testbar
/// ist.
public protocol SecretStore: Sendable {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// Generic-Password-Einträge im Keychain, alle unter einem `service`.
///
/// Bewusst **ohne** `kSecUseDataProtectionKeychain` auf macOS: der verlangt
/// ein `application-identifier`-Entitlement, das der Developer-ID-Build nicht
/// trägt. Der klassische Datei-Keychain reicht — die App legt den Eintrag
/// selbst an und steht damit in seiner ACL, es gibt also keinen Prompt.
public struct KeychainSecretStore: SecretStore {

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }

    public let service: String

    public init(service: String = "ch.buehler.beat.SetCraft") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    public func string(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }

        var add = baseQuery(account)
        add[kSecValueData] = data
        // Nach dem ersten Entsperren lesbar: ein Analyse-Lauf im Hintergrund
        // soll den Token nicht an einer Sperre verlieren. Nicht synchronisiert
        // — der Token bleibt auf dem Gerät, auf dem er eingegeben wurde.
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status)
        }
    }
}

/// Der Discogs Personal Access Token — früher im Klartext unter
/// `discogs.token` in `UserDefaults`, jetzt im Keychain.
///
/// Leerer String heisst „kein Token", so wie es die Sheets bisher behandelt
/// haben; gespeichert wird er dann gar nicht.
public struct DiscogsTokenStore {

    /// Alter `UserDefaults`-Schlüssel, nur noch für die Migration.
    public static let legacyDefaultsKey = "discogs.token"
    static let account = "discogs.token"

    private static let log = Logger(
        subsystem: "ch.buehler.beat.SetCraft", category: "Secrets"
    )

    private let secrets: any SecretStore
    private let defaults: UserDefaults

    public init(secrets: any SecretStore = KeychainSecretStore(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
    }

    /// Liest den Token; ein noch im Klartext liegender Wert wird dabei in
    /// den Keychain übernommen. Der alte Wert wird erst gelöscht, wenn der
    /// Keychain ihn nachweislich zurückgibt — scheitert ein Schritt, bleibt
    /// alles, wie es war, und der nächste Aufruf versucht es erneut.
    public func load() -> String {
        migrateIfNeeded()
        do {
            return try secrets.string(for: Self.account) ?? ""
        } catch {
            Self.log.error("Reading Discogs token failed: \(String(describing: error), privacy: .public)")
            // Migration gescheitert und Keychain nicht lesbar: lieber der
            // alte Wert als gar keiner.
            return defaults.string(forKey: Self.legacyDefaultsKey) ?? ""
        }
    }

    /// Speichert den Token; leer oder nur Leerzeichen entfernt ihn.
    public func save(_ token: String) {
        do {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try secrets.remove(Self.account)
            } else {
                try secrets.set(token, for: Self.account)
            }
            // Falls die Migration noch aussteht: ein neuer Wert ersetzt den
            // alten, der Klartext darf nicht zurückkommen.
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        } catch {
            Self.log.error("Saving Discogs token failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func migrateIfNeeded() {
        guard let legacy = defaults.string(forKey: Self.legacyDefaultsKey) else { return }
        guard !legacy.isEmpty else {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return
        }
        do {
            // Ein schon vorhandener Keychain-Wert ist neuer als der Klartext
            // (save() räumt den Klartext sonst mit ab) — nicht überschreiben.
            if try secrets.string(for: Self.account) == nil {
                try secrets.set(legacy, for: Self.account)
            }
            guard try secrets.string(for: Self.account) != nil else { return }
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            Self.log.info("Migrated Discogs token from UserDefaults to Keychain")
        } catch {
            Self.log.error("Migrating Discogs token failed: \(String(describing: error), privacy: .public)")
        }
    }
}
