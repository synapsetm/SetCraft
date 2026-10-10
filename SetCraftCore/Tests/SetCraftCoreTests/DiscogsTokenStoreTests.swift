import XCTest
@testable import SetCraftCore

final class DiscogsTokenStoreTests: XCTestCase {

    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        var values: [String: String] = [:]
        var failWrites = false

        func string(for account: String) throws -> String? { values[account] }
        func set(_ value: String, for account: String) throws {
            if failWrites { throw KeychainSecretStore.Failure(status: errSecIO) }
            values[account] = value
        }
        func remove(_ account: String) throws { values[account] = nil }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "DiscogsTokenStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_legacyTokenMovesToKeychain() {
        defaults.set("abc123", forKey: DiscogsTokenStore.legacyDefaultsKey)
        let secrets = MemorySecrets()
        let store = DiscogsTokenStore(secrets: secrets, defaults: defaults)

        XCTAssertEqual(store.load(), "abc123")
        XCTAssertEqual(secrets.values[DiscogsTokenStore.account], "abc123")
        XCTAssertNil(defaults.string(forKey: DiscogsTokenStore.legacyDefaultsKey))
    }

    func test_failedKeychainWriteKeepsLegacyValue() {
        defaults.set("abc123", forKey: DiscogsTokenStore.legacyDefaultsKey)
        let secrets = MemorySecrets()
        secrets.failWrites = true
        let store = DiscogsTokenStore(secrets: secrets, defaults: defaults)

        XCTAssertEqual(store.load(), "")
        XCTAssertEqual(defaults.string(forKey: DiscogsTokenStore.legacyDefaultsKey), "abc123",
                       "Ohne bestätigten Keychain-Eintrag darf der alte Wert nicht verschwinden")
    }

    func test_existingKeychainValueWinsOverLegacy() {
        defaults.set("old", forKey: DiscogsTokenStore.legacyDefaultsKey)
        let secrets = MemorySecrets()
        secrets.values[DiscogsTokenStore.account] = "new"
        let store = DiscogsTokenStore(secrets: secrets, defaults: defaults)

        XCTAssertEqual(store.load(), "new")
        XCTAssertNil(defaults.string(forKey: DiscogsTokenStore.legacyDefaultsKey))
    }

    func test_saveEmptyRemovesToken() {
        let secrets = MemorySecrets()
        let store = DiscogsTokenStore(secrets: secrets, defaults: defaults)

        store.save("abc")
        XCTAssertEqual(store.load(), "abc")
        store.save("  ")
        XCTAssertEqual(store.load(), "")
        XCTAssertNil(secrets.values[DiscogsTokenStore.account])
    }
}
