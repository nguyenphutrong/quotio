import XCTest
@testable import Quotio

final class CodexAuthConfigTests: XCTestCase {

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A realistic ChatGPT-login auth.json as Codex CLI writes it.
    private func nativeAuthData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "id_token": "native-id-token",
                "access_token": "native-access-token",
                "refresh_token": "native-refresh-token",
                "account_id": "11111111-2222-3333-4444-555555555555"
            ],
            "last_refresh": "2026-01-01T00:00:00Z"
        ])
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-codex-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    // MARK: - codexAuthPayloads
    //
    // The manual preview renders `managed` and "Copy All" copies it, so it must
    // never carry the user's native Codex credentials. Only `merged` — which is
    // written straight to disk in automatic mode — may contain them.

    func testManualPayloadNeverExposesNativeCredentials() throws {
        let payloads = AgentConfigurationService.codexAuthPayloads(
            existing: try nativeAuthData(),
            apiKey: "quotio-local-test",
            path: "/tmp/auth.json"
        )

        let managed = try jsonObject(Data(payloads.managed.utf8))
        XCTAssertEqual(managed.count, 1)
        XCTAssertEqual(managed["OPENAI_API_KEY"] as? String, "quotio-local-test")

        // Guard the rendered text too: this is the exact string shown and copied.
        for secret in ["native-access-token", "native-refresh-token", "native-id-token",
                       "11111111-2222-3333-4444-555555555555", "last_refresh"] {
            XCTAssertFalse(
                payloads.managed.contains(secret),
                "manual auth.json preview leaked \(secret)"
            )
        }
    }

    func testAutomaticPayloadMergesIntoExistingFile() throws {
        let payloads = AgentConfigurationService.codexAuthPayloads(
            existing: try nativeAuthData(),
            apiKey: "quotio-local-test",
            path: "/tmp/auth.json"
        )

        let merged = try jsonObject(Data(payloads.merged.utf8))
        XCTAssertEqual(merged["OPENAI_API_KEY"] as? String, "quotio-local-test")
        let tokens = try XCTUnwrap(merged["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["refresh_token"] as? String, "native-refresh-token")
        XCTAssertEqual(merged["last_refresh"] as? String, "2026-01-01T00:00:00Z")
    }

    func testPayloadsFallBackToManagedOnlyWhenExistingFileIsCorrupt() throws {
        let payloads = AgentConfigurationService.codexAuthPayloads(
            existing: Data("not json".utf8),
            apiKey: "quotio-local-test",
            path: "/tmp/auth.json"
        )

        XCTAssertEqual(payloads.merged, payloads.managed)
        let merged = try jsonObject(Data(payloads.merged.utf8))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["OPENAI_API_KEY"] as? String, "quotio-local-test")
    }

    func testPayloadsWithNoExistingFileAreIdentical() throws {
        let payloads = AgentConfigurationService.codexAuthPayloads(
            existing: nil,
            apiKey: "quotio-local-test",
            path: "/tmp/auth.json"
        )
        XCTAssertEqual(payloads.merged, payloads.managed)
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

    // MARK: - revertCodexAuthJSON
    //
    // The revert must not depend on config.toml: "Use default" previously nested
    // the auth.json cleanup inside the config.toml branch, so a user whose
    // config.toml was already gone kept the Quotio key forever.

    func testRevertRemovesManagedKeyWithoutAnyConfigTOML() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let authPath = dir.appendingPathComponent("auth.json").path
        try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": "quotio-local-test",
            "tokens": ["refresh_token": "native-refresh-token"]
        ]).write(to: URL(fileURLWithPath: authPath))

        // No config.toml exists in this directory at all.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.toml").path))

        let changed = try await AgentConfigurationService().revertCodexAuthJSON(at: authPath)
        XCTAssertTrue(changed)

        let object = try jsonObject(try Data(contentsOf: URL(fileURLWithPath: authPath)))
        XCTAssertNil(object["OPENAI_API_KEY"])
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["refresh_token"] as? String, "native-refresh-token")

        // A collision-safe backup of the pre-revert file is left behind.
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("auth.json.backup.") }
        XCTAssertEqual(backups.count, 1)

        let perms = try FileManager.default.attributesOfItem(atPath: authPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    func testRevertLeavesUserOwnedKeyAndReportsNoChange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let authPath = dir.appendingPathComponent("auth.json").path
        let original = #"{"OPENAI_API_KEY":"sk-user-owned-key"}"#
        try original.write(toFile: authPath, atomically: true, encoding: .utf8)

        let changed = try await AgentConfigurationService().revertCodexAuthJSON(at: authPath)
        XCTAssertFalse(changed)
        XCTAssertEqual(try String(contentsOfFile: authPath, encoding: .utf8), original)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("auth.json.backup.") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testRevertIsANoOpWhenAuthFileIsMissing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let changed = try await AgentConfigurationService()
            .revertCodexAuthJSON(at: dir.appendingPathComponent("auth.json").path)
        XCTAssertFalse(changed)
    }

    // MARK: - Backups

    /// Two reverts in the same second must not clobber the first backup.
    func testRepeatedRevertsKeepEveryBackup() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = AgentConfigurationService()
        let authPath = dir.appendingPathComponent("auth.json").path

        try #"{"OPENAI_API_KEY":"quotio-local-1","account_id":"first"}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        let firstRevert = try await service.revertCodexAuthJSON(at: authPath)
        XCTAssertTrue(firstRevert)

        try #"{"OPENAI_API_KEY":"quotio-local-2","account_id":"second"}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        let secondRevert = try await service.revertCodexAuthJSON(at: authPath)
        XCTAssertTrue(secondRevert)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("auth.json.backup.") }
        XCTAssertEqual(backups.count, 2, "a same-second backup overwrote an earlier one")

        let contents = try backups.map {
            try String(contentsOfFile: dir.appendingPathComponent($0).path, encoding: .utf8)
        }
        XCTAssertTrue(contents.contains { $0.contains("quotio-local-1") })
        XCTAssertTrue(contents.contains { $0.contains("quotio-local-2") })
    }

    func testRestoreFromBackupRestoresOriginalAuthJSON() async throws {
        let fileManager = FileManager.default
        let tempDir = try makeTempDir()
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
