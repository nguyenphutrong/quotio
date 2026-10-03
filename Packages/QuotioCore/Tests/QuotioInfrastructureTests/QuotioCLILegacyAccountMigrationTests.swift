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

    func testCodexKeychainMigrationWithoutMetadataRetriesAndThenStopsReadingSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let source = CodexMigrationKeychain()
        let destination = MigrationDestination()
        let metadataURL = directory.appendingPathComponent("missing.json")
        let migration = QuotioCLILegacyAccountMigration(
            metadataURL: metadataURL, credentials: MigrationCredentials(), defaults: UserDefaults(suiteName: suite)!,
            codexKeychain: source, importAccount: { account, credential, disabled in
                try await destination.save(account, credential: credential, disabled: disabled)
            }
        )
        let unavailable = await migration.migrate()
        XCTAssertEqual(unavailable, CredentialMigrationResult(pendingCount: 1))
        await destination.allowWrites()
        let imported = await migration.migrate()
        XCTAssertEqual(imported, CredentialMigrationResult(migratedCount: 1))
        let received = await destination.credentials.values.first
        XCTAssertEqual(received?.accountID, "codex-account")
        XCTAssertEqual(received?.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(received?.idToken, CodexMigrationKeychain.idToken)
        XCTAssertEqual(received?.refreshToken, "synthetic-refresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        let restarted = QuotioCLILegacyAccountMigration(
            metadataURL: metadataURL, credentials: MigrationCredentials(), defaults: UserDefaults(suiteName: suite)!,
            codexKeychain: source, importAccount: { _, _, _ in XCTFail("Must not import twice") }
        )
        let replay = await restarted.migrate()
        XCTAssertEqual(replay, CredentialMigrationResult())
        let reads = await source.readCount
        XCTAssertEqual(reads, 2)
    }

    func testCodexKeychainMigrationKeepsLegacyDisabledStateAndRetriesMalformedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let metadataURL = directory.appendingPathComponent("accounts.json")
        let repository = FileAccountMetadataRepository(url: metadataURL)
        let account = Account.make(providerID: AccountProviderID(rawValue: "codex"), accountKey: "Legacy alias", source: .nativeCredential, credentialReference: "keychain:Codex Auth")
        try await repository.saveAccount(account)
        try await repository.setDisabled(true, accountID: account.id)
        let original = try Data(contentsOf: metadataURL)
        let source = CodexMigrationKeychain()
        await source.setData(Data("invalid".utf8))
        let destination = MigrationDestination()
        await destination.allowWrites()
        let migration = QuotioCLILegacyAccountMigration(
            metadataURL: metadataURL, credentials: MigrationCredentials(), defaults: UserDefaults(suiteName: suite)!,
            codexKeychain: source, importAccount: { account, credential, disabled in
                try await destination.save(account, credential: credential, disabled: disabled)
            }
        )
        let failed = await migration.migrate()
        XCTAssertEqual(failed, CredentialMigrationResult(pendingCount: 1))
        await source.setData(nil)
        let locked = await migration.migrate()
        XCTAssertEqual(locked, CredentialMigrationResult(pendingCount: 1))
        await source.setData(CodexMigrationKeychain.fixture)
        let imported = await migration.migrate()
        XCTAssertEqual(imported, CredentialMigrationResult(migratedCount: 1))
        let saved = await destination.saved
        XCTAssertEqual(saved, [account.id: true])
        XCTAssertEqual(try Data(contentsOf: metadataURL), original)
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
    var credentials: [String: StoredCredential] = [:]
    func allowWrites() { allowed = true }
    func save(_ account: Account, credential: StoredCredential, disabled: Bool) throws {
        attempts.append(account.id)
        guard allowed else { throw QuotioCLIBackendError.disconnected }
        XCTAssertEqual(credential.refreshToken, "synthetic-refresh")
        saved[account.id] = disabled
        credentials[account.id] = credential
    }
}

private actor CodexMigrationKeychain: ExternalCredentialReading {
    static let idToken = jwt(#"{"email":"person@example.test","https://api.openai.com/auth":{"chatgpt_account_id":"codex-account"}}"#)
    static let fixture = try! JSONSerialization.data(withJSONObject: ["tokens": [
        "access_token": jwt(#"{"exp":2000000000}"#), "refresh_token": "synthetic-refresh", "id_token": idToken,
    ]])
    private var data: Data? = fixture
    private(set) var readCount = 0
    func setData(_ data: Data?) { self.data = data }
    func read(service: String, account: String?) -> ExternalCredentialRecord? {
        XCTAssertEqual(service, "Codex Auth")
        XCTAssertNil(account)
        readCount += 1
        return data.map { ExternalCredentialRecord(data: $0, account: "legacy") }
    }
    func compareAndSwap(service: String, account: String, expectedData: Data, newData: Data) -> Bool {
        XCTFail("Migration must never write the source Keychain item")
        return false
    }
    private static func jwt(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).signature"
    }
}
