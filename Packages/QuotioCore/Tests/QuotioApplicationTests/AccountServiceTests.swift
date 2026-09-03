import Foundation
import QuotioDomain
import XCTest
@testable import QuotioApplication

final class AccountServiceTests: XCTestCase {
    func testSaveAPIKeyPersistsCredentialOutsidePresentationAccount() async throws {
        let providerID = AccountProviderID(rawValue: "openrouter")
        let discovery = AccountServiceDiscovery()
        let metadata = AccountServiceMetadataRepository()
        let vault = AccountServiceCredentialVault()
        let service = AccountService(
            discovery: discovery,
            metadataRepository: metadata,
            credentialVault: vault
        )

        try await service.saveAPIKey(
            providerID: providerID,
            label: "Work",
            apiKey: "secret-key",
            existingAccountID: nil
        )

        let saved = await vault.saved
        XCTAssertEqual(saved?.credential.accessToken, "secret-key")
        XCTAssertEqual(saved?.account.accountKey, "Work")
        XCTAssertEqual(saved?.account.credentialMetadata?.kind, .apiKey)
        XCTAssertFalse(String(describing: saved?.account).contains("secret-key"))
    }

    func testSaveAPIKeyRejectsDuplicateAndReservedLabels() async throws {
        let providerID = AccountProviderID(rawValue: "amp")
        let account = Account.make(
            providerID: providerID,
            accountKey: "Work",
            source: .quotioKeychain,
            capabilities: [.disable, .delete, .edit]
        )
        let discovery = AccountServiceDiscovery(accounts: [account])
        let service = AccountService(
            discovery: discovery,
            metadataRepository: AccountServiceMetadataRepository(),
            credentialVault: AccountServiceCredentialVault(),
            reservedLabels: [providerID: ["Amp CLI"]]
        )

        await XCTAssertThrowsAccountServiceError(
            try await service.saveAPIKey(
                providerID: providerID,
                label: "work",
                apiKey: "secret",
                existingAccountID: nil
            ),
            expected: .duplicateAccount
        )
        await XCTAssertThrowsAccountServiceError(
            try await service.saveAPIKey(
                providerID: providerID,
                label: "amp cli",
                apiKey: "secret",
                existingAccountID: nil
            ),
            expected: .invalidCredential
        )
    }

    func testDeleteHonorsAccountCapability() async throws {
        let providerID = AccountProviderID(rawValue: "codex")
        let protected = Account.make(
            providerID: providerID,
            accountKey: "Native",
            source: .nativeCredential
        )
        let owned = Account.make(
            providerID: providerID,
            accountKey: "Owned",
            source: .quotioKeychain,
            capabilities: [.disable, .delete]
        )
        let vault = AccountServiceCredentialVault()
        let service = AccountService(
            discovery: AccountServiceDiscovery(accounts: [protected, owned]),
            metadataRepository: AccountServiceMetadataRepository(),
            credentialVault: vault
        )

        await XCTAssertThrowsAccountServiceError(
            try await service.delete(accountID: protected.id),
            expected: .deletionNotAllowed
        )
        try await service.delete(accountID: owned.id)

        let deletedAccountIDs = await vault.deletedAccountIDs
        XCTAssertEqual(deletedAccountIDs, [owned.id])
    }
}

private actor AccountServiceDiscovery: AccountDiscovering {
    private let storedAccounts: [Account]

    init(accounts: [Account] = []) {
        storedAccounts = accounts
    }

    func discoverAccounts() -> [Account] {
        storedAccounts
    }
}

private actor AccountServiceMetadataRepository: AccountMetadataRepository {
    func accounts() -> [Account] { [] }
    func disabledAccountIDs() -> Set<String> { [] }
    func saveAccount(_ account: Account) {}
    func deleteAccount(_ accountID: String) {}
    func setDisabled(_ disabled: Bool, accountID: String) {}
}

private actor AccountServiceCredentialVault: CredentialVault {
    private(set) var saved: (credential: StoredCredential, account: Account)?
    private(set) var deletedAccountIDs: [String] = []

    func accounts() -> [Account] { [] }
    func credential(for accountID: String) -> StoredCredential? { nil }
    func reloadLatest(accountID: String) -> StoredCredential? { nil }

    func save(_ credential: StoredCredential, metadata account: Account) {
        saved = (credential, account)
    }

    func delete(accountID: String) {
        deletedAccountIDs.append(accountID)
    }
}

private func XCTAssertThrowsAccountServiceError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: AccountServiceFailure,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected AccountServiceFailure", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AccountServiceFailure, expected, file: file, line: line)
    }
}
