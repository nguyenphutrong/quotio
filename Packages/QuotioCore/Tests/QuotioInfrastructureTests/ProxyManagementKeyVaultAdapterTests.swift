import Foundation
import QuotioApplication
import XCTest
@testable import QuotioInfrastructure

final class ProxyManagementKeyVaultAdapterTests: XCTestCase {
    func testLoadMigratesPlaintextLegacyDefaultAfterDurableSave() async {
        let suite = "ProxyManagementKeyVaultAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-key", forKey: "managementKey")
        let store = CredentialDataStoreFake()
        let vault = ProxyManagementKeyVaultAdapter(dataStore: store, defaultsSuiteName: suite)

        let loaded = await vault.loadManagementKey()
        let stored = await store.string(accountID: "local-management-key")

        XCTAssertEqual(loaded, "legacy-key")
        XCTAssertNil(defaults.string(forKey: "managementKey"))
        XCTAssertEqual(stored, "legacy-key")
    }

    func testLoadKeepsLegacyDefaultWhenDurableSaveFails() async {
        let suite = "ProxyManagementKeyVaultAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-key", forKey: "managementKey")
        let store = CredentialDataStoreFake(allowsSaves: false)
        let vault = ProxyManagementKeyVaultAdapter(dataStore: store, defaultsSuiteName: suite)

        let loaded = await vault.loadManagementKey()

        XCTAssertEqual(loaded, "legacy-key")
        XCTAssertEqual(defaults.string(forKey: "managementKey"), "legacy-key")
    }

    func testLoadDoesNotTreatLegacyHashAsManagementKey() async {
        let suite = "ProxyManagementKeyVaultAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("$2a$legacy-hash", forKey: "managementKey")
        let vault = ProxyManagementKeyVaultAdapter(
            dataStore: CredentialDataStoreFake(),
            defaultsSuiteName: suite
        )

        let loaded = await vault.loadManagementKey()
        XCTAssertNil(loaded)
        XCTAssertEqual(defaults.string(forKey: "managementKey"), "$2a$legacy-hash")
    }
}

private actor CredentialDataStoreFake: CredentialDataStoring {
    private let allowsSaves: Bool
    private var values: [String: Data] = [:]

    init(allowsSaves: Bool = true) {
        self.allowsSaves = allowsSaves
    }

    func read(accountID: String) -> CredentialDataRecord? {
        values[accountID].map { CredentialDataRecord(data: $0, generation: "generation") }
    }

    func save(_ data: Data, accountID: String) -> CredentialDataRecord? {
        guard allowsSaves else { return nil }
        values[accountID] = data
        return CredentialDataRecord(data: data, generation: "generation")
    }

    func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration _: String
    ) -> CredentialDataRecord? {
        save(data, accountID: accountID)
    }

    func delete(accountID: String) {
        values[accountID] = nil
    }

    func string(accountID: String) -> String? {
        values[accountID].flatMap { String(data: $0, encoding: .utf8) }
    }
}
