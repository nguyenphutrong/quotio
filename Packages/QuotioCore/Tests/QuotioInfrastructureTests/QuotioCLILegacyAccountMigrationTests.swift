import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class QuotioCLILegacyAccountMigrationTests: XCTestCase {
    func testMigrationRetainsSourceAndRetriesOnlyUncommittedAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts-v1.json")
        let suite = UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let repository = FileAccountMetadataRepository(url: url)
        for id in ["first", "locked"] {
            try await repository.saveAccount(Account(
                identity: AccountIdentity(id: id, providerID: AccountProviderID(rawValue: "claude"), accountKey: id),
                displayName: id, source: .quotioKeychain, credentialReference: "keychain", capabilities: [.delete], status: .ready
            ))
        }
        try await repository.setDisabled(true, accountID: "first")
        let original = try Data(contentsOf: url)
        let credentials = MigrationCredentials()
        let destination = MigrationDestination()
        let migration = QuotioCLILegacyAccountMigration(metadataURL: url, credentials: credentials, defaults: UserDefaults(suiteName: suite)!, importAccount: { account, credential, disabled in try await destination.save(account, credential: credential, disabled: disabled) })
        let failed = await migration.migrate()
        XCTAssertEqual(failed, CredentialMigrationResult(pendingCount: 2))
        await destination.allowWrites()
        let partial = await migration.migrate()
        XCTAssertEqual(partial, CredentialMigrationResult(migratedCount: 1, pendingCount: 1))
        await credentials.unlock()
        let complete = await migration.migrate()
        XCTAssertEqual(complete, CredentialMigrationResult(migratedCount: 1))
        let replay = await migration.migrate()
        XCTAssertEqual(replay, CredentialMigrationResult())
        let saved = await destination.saved
        XCTAssertEqual(saved, ["first": true, "locked": false])
        let attempts = await destination.attempts
        XCTAssertEqual(attempts, ["first", "first", "locked"])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnreadableMetadataIsReportedAndMissingMetadataIsNormal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.json")
        let migration = QuotioCLILegacyAccountMigration(metadataURL: url, credentials: MigrationCredentials(), importAccount: { _, _, _ in XCTFail("Must not import") })
        let missing = await migration.migrate()
        XCTAssertEqual(missing, CredentialMigrationResult())
        try Data("invalid".utf8).write(to: url)
        let corrupt = await migration.migrate()
        XCTAssertTrue(corrupt.metadataUnreadable)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "invalid")
    }
}

private actor MigrationCredentials: CredentialDataStoring {
    var unlocked = false
    func unlock() { unlocked = true }
    func read(accountID: String) -> CredentialDataRecord? {
        guard accountID != "locked" || unlocked else { return nil }
        let credential = StoredCredential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil, accountID: accountID, expiresAt: Date(timeIntervalSince1970: 1), extra: [:])
        return CredentialDataRecord(data: try! JSONEncoder().encode(credential), generation: "v1")
    }
    func save(_ data: Data, accountID: String) -> CredentialDataRecord? { XCTFail("Source must not be written"); return nil }
    func compareAndSwap(_ data: Data, accountID: String, expectedGeneration: String) -> CredentialDataRecord? { XCTFail("Source must not be written"); return nil }
    func delete(accountID: String) { XCTFail("Source must not be deleted") }
}

private actor MigrationDestination {
    var allowed = false
    var saved: [String: Bool] = [:]
    var attempts: [String] = []
    func allowWrites() { allowed = true }
    func save(_ account: Account, credential: StoredCredential, disabled: Bool) throws {
        attempts.append(account.id)
        guard allowed else { throw QuotioCLIBackendError.disconnected }
        XCTAssertEqual(credential.refreshToken, "synthetic-refresh")
        saved[account.id] = disabled
    }
}
