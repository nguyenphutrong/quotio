import XCTest
@testable import Quotio

final class CodexAuthConfigTests: XCTestCase {

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - mergedCodexAuthJSON

    func testMergePreservesNativeFieldsAndSetsProxyKey() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "access_token": "native-access-token",
            "account_id": "11111111-2222-3333-4444-555555555555",
            "tokens": [
                "access_token": "native-access-token",
                "account_id": "11111111-2222-3333-4444-555555555555"
            ],
            "last_refresh": "2026-01-01T00:00:00Z",
            "OPENAI_API_KEY": "old-key"
        ])

        let merged = try AgentConfigurationService.mergedCodexAuthJSON(
            existing: existing,
            apiKey: "quotio-local-test"
        )
        let object = try jsonObject(merged)

        XCTAssertEqual(object["OPENAI_API_KEY"] as? String, "quotio-local-test")
        XCTAssertEqual(object["access_token"] as? String, "native-access-token")
        XCTAssertEqual(object["account_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(object["last_refresh"] as? String, "2026-01-01T00:00:00Z")
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["account_id"] as? String, "11111111-2222-3333-4444-555555555555")
    }

    func testMergeWithoutExistingFileProducesOnlyProxyKey() throws {
        let merged = try AgentConfigurationService.mergedCodexAuthJSON(
            existing: nil,
            apiKey: "quotio-local-test"
        )
        let object = try jsonObject(merged)

        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(object["OPENAI_API_KEY"] as? String, "quotio-local-test")
    }

    func testMergeThrowsOnCorruptExistingContent() {
        let corrupt = Data("not json".utf8)
        XCTAssertThrowsError(
            try AgentConfigurationService.mergedCodexAuthJSON(existing: corrupt, apiKey: "quotio-local-test")
        )
    }

    // MARK: - codexAuthJSONRemovingQuotioKey

    func testRemoveQuotioKeyPreservesNativeCredentials() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "access_token": "native-access-token",
            "account_id": "11111111-2222-3333-4444-555555555555",
            "OPENAI_API_KEY": "quotio-local-test"
        ])

        let cleaned = try XCTUnwrap(
            AgentConfigurationService.codexAuthJSONRemovingQuotioKey(existing: existing)
        )
        let object = try jsonObject(cleaned)

        XCTAssertNil(object["OPENAI_API_KEY"])
        XCTAssertEqual(object["access_token"] as? String, "native-access-token")
        XCTAssertEqual(object["account_id"] as? String, "11111111-2222-3333-4444-555555555555")
    }

    func testRemoveLeavesUserOwnedKeyUntouched() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": "sk-user-owned-key"
        ])
        XCTAssertNil(try AgentConfigurationService.codexAuthJSONRemovingQuotioKey(existing: existing))
    }

    func testRemoveReturnsNilWhenNoKeyPresent() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "account_id": "11111111-2222-3333-4444-555555555555"
        ])
        XCTAssertNil(try AgentConfigurationService.codexAuthJSONRemovingQuotioKey(existing: existing))
    }

    // MARK: - Backup restore

    func testRestoreFromBackupRestoresOriginalAuthJSON() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("quotio-codex-auth-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let authPath = tempDir.appendingPathComponent("auth.json").path
        let originalContent = "{\"account_id\":\"native\"}"
        let timestamp = 1736840000
        let backupPath = "\(authPath).backup.\(timestamp)"

        // Simulate the state after Quotio configured the proxy:
        // a timestamped backup holds the native file, the live file holds the proxy key.
        try originalContent.write(toFile: backupPath, atomically: true, encoding: .utf8)
        try "{\"OPENAI_API_KEY\":\"quotio-local-test\"}".write(toFile: authPath, atomically: true, encoding: .utf8)

        let service = AgentConfigurationService()
        let backup = AgentConfigurationService.BackupFile(
            path: backupPath,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            agent: .codexCLI
        )
        try await service.restoreFromBackup(backup)

        let restored = try String(contentsOfFile: authPath, encoding: .utf8)
        XCTAssertEqual(restored, originalContent)
    }
}
