import Foundation
import XCTest
@testable import QuotioApplication
import QuotioDomain

final class CredentialVaultServiceTests: XCTestCase {
    func testCompareAndSwapDoesNotOverwriteNewerCredential() async throws {
        let dataStore = FakeCredentialDataStore()
        let metadata = FakeAccountMetadataRepository()
        let vault = CredentialVaultService(dataStore: dataStore, metadataRepository: metadata)
        let account = Account.make(
            providerID: AccountProviderID(rawValue: "codex"),
            accountKey: "person@example.com",
            source: .quotioKeychain,
            capabilities: [.disable, .delete]
        )
        let original = StoredCredential(
            accessToken: "original",
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )
        let stale = StoredCredential(
            accessToken: "stale",
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )

        try await vault.save(original, metadata: account)
        _ = await vault.credential(for: account.id)
        try await dataStore.replaceWithNewerCredential(accountID: account.id)

        do {
            try await vault.save(stale, metadata: account)
            XCTFail("Expected stale compare-and-swap to fail")
        } catch CredentialVaultError.writeFailed {
            // Expected.
        }

        let storedAccessToken = await dataStore.accessToken(accountID: account.id)
        XCTAssertEqual(storedAccessToken, "newer")
    }

    func testCredentialMetadataContainsNoSecretValues() {
        let credential = StoredCredential(
            accessToken: "secret-access",
            refreshToken: "secret-refresh",
            idToken: "secret-id",
            accountID: "account-1",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            extra: ["clientSecret": "secret-client"]
        )

        let metadata = credential.redactedMetadata
        let description = String(describing: metadata)

        XCTAssertEqual(metadata.kind, .oauth)
        XCTAssertTrue(metadata.hasRefreshToken)
        XCTAssertTrue(metadata.hasAccountIdentifier)
        XCTAssertFalse(description.contains("secret"))
        XCTAssertFalse(description.contains("account-1"))
    }
}

private actor FakeCredentialDataStore: CredentialDataStoring {
    private var records: [String: CredentialDataRecord] = [:]
    private var generation = 0

    func read(accountID: String) -> CredentialDataRecord? {
        records[accountID]
    }

    func save(_ data: Data, accountID: String) -> CredentialDataRecord? {
        generation += 1
        let record = CredentialDataRecord(data: data, generation: String(generation))
        records[accountID] = record
        return record
    }

    func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) -> CredentialDataRecord? {
        guard records[accountID]?.generation == expectedGeneration else { return nil }
        generation += 1
        let record = CredentialDataRecord(data: data, generation: String(generation))
        records[accountID] = record
        return record
    }

    func delete(accountID: String) {
        records.removeValue(forKey: accountID)
    }

    func replaceWithNewerCredential(accountID: String) throws {
        let credential = StoredCredential(
            accessToken: "newer",
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )
        records[accountID] = save(try JSONEncoder().encode(credential), accountID: accountID)
    }

    func accessToken(accountID: String) -> String? {
        guard let data = records[accountID]?.data else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data).accessToken
    }
}

private actor FakeAccountMetadataRepository: AccountMetadataRepository {
    private var storedAccounts: [Account] = []
    private var disabledIDs: Set<String> = []

    func accounts() -> [Account] { storedAccounts }
    func disabledAccountIDs() -> Set<String> { disabledIDs }

    func saveAccount(_ account: Account) {
        storedAccounts.removeAll { $0.id == account.id }
        storedAccounts.append(account)
    }

    func deleteAccount(_ accountID: String) {
        storedAccounts.removeAll { $0.id == accountID }
        disabledIDs.remove(accountID)
    }

    func setDisabled(_ disabled: Bool, accountID: String) {
        if disabled { disabledIDs.insert(accountID) }
        else { disabledIDs.remove(accountID) }
    }
}
