import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class CodexAgentConfigurationAdapterTests: XCTestCase {
    func testPreviewIsSecretSafeAndDoesNotWriteFiles() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"native-secret"}}"#.utf8).write(to: authURL)
        let adapter = CodexAgentConfigurationAdapter(fileStore: AgentFileStore(homeDirectory: home.path))

        let result = try await adapter.preview(request(mode: .manual))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.mode, .manual)
        XCTAssertEqual(result.modelsConfigured, 1)
        XCTAssertFalse(result.rawConfigs.map(\.content).joined().contains("native-secret"))
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8), #"{"tokens":{"access_token":"native-secret"}}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    func testAutomaticApplyPreservesAuthSetsPermissionsInspectsAndListsCollisionSafeBackups() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let config = codex.appendingPathComponent("config.toml")
        let auth = codex.appendingPathComponent("auth.json")
        try "approval_policy = \"never\"\n".write(to: config, atomically: true, encoding: .utf8)
        try Data(#"{"tokens":{"refresh_token":"native"}}"#.utf8).write(to: auth)
        let fixedDate = Date(timeIntervalSince1970: 1_736_840_000)
        let adapter = CodexAgentConfigurationAdapter(
            fileStore: AgentFileStore(homeDirectory: home.path, now: { fixedDate })
        )

        _ = try await adapter.apply(request(mode: .automatic))
        _ = try await adapter.apply(request(mode: .automatic))

        let authObject = try json(Data(contentsOf: auth))
        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, "quotio-test")
        XCTAssertEqual((authObject["tokens"] as? [String: Any])?["refresh_token"] as? String, "native")
        let permissions = try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let inspectedValue = await adapter.inspect()
        let inspected = try XCTUnwrap(inspectedValue)
        XCTAssertEqual(inspected.modelSlots[.sonnet], "gpt-5-codex")
        XCTAssertEqual(inspected.reasoningEffort, .custom("turbo"))
        XCTAssertTrue(inspected.isProxyConfigured)
        let backups = await adapter.listBackups()
        XCTAssertEqual(backups.filter { $0.path.contains("config.toml.backup") }.count, 2)
        XCTAssertEqual(backups.filter { $0.path.contains("auth.json.backup") }.count, 2)

        try await adapter.restore(try XCTUnwrap(backups.first { $0.path.hasSuffix("config.toml.backup.1736840000") }))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "approval_policy = \"never\"\n")
    }

    func testSecondWriteFailureRollsBackBothFiles() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let config = codex.appendingPathComponent("config.toml")
        let auth = codex.appendingPathComponent("auth.json")
        let oldConfig = "model = \"original\"\n"
        let oldAuth = Data(#"{"OPENAI_API_KEY":"old","native":"kept"}"#.utf8)
        try oldConfig.write(to: config, atomically: true, encoding: .utf8)
        try oldAuth.write(to: auth)
        let store = AgentFileStore(homeDirectory: home.path, beforeWrite: { _, index in
            if index == 1 { throw CocoaError(.fileWriteUnknown) }
        })

        do {
            _ = try await CodexAgentConfigurationAdapter(fileStore: store).apply(request(mode: .automatic))
            XCTFail("Expected the injected second write to fail")
        } catch {}

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), oldConfig)
        XCTAssertEqual(try Data(contentsOf: auth), oldAuth)
    }

    func testResetCleansConfigAndAuthIndependentlyAndPreservesNativeData() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let auth = codex.appendingPathComponent("auth.json")
        try Data(#"{"OPENAI_API_KEY":"quotio-test","native":"kept"}"#.utf8).write(to: auth)
        let adapter = CodexAgentConfigurationAdapter(fileStore: AgentFileStore(homeDirectory: home.path))

        _ = try await adapter.reset(mode: .automatic)

        let object = try json(Data(contentsOf: auth))
        XCTAssertNil(object["OPENAI_API_KEY"])
        XCTAssertEqual(object["native"] as? String, "kept")

        let config = codex.appendingPathComponent("config.toml")
        try CodexConfigurationCodec.managedTOML(model: "old", proxyURL: "http://localhost")
            .appending("\n[profiles.work]\nmodel = \"kept\"\n")
            .write(to: config, atomically: true, encoding: .utf8)
        try Data(#"{"OPENAI_API_KEY":"sk-user","native":"kept"}"#.utf8).write(to: auth)
        _ = try await adapter.reset(mode: .automatic)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("[profiles.work]"))
        XCTAssertEqual(try json(Data(contentsOf: auth))["OPENAI_API_KEY"] as? String, "sk-user")
    }

    func testRejectsConfigurationForAnotherAgent() async throws {
        var configuration = AgentConfiguration(agent: .claudeCode, proxyURL: "http://localhost:8317/v1", apiKey: "key")
        configuration.modelSlots = [.opus: "a", .sonnet: "b", .haiku: "c"]
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = CodexAgentConfigurationAdapter(fileStore: AgentFileStore(homeDirectory: home.path))

        await XCTAssertThrowsErrorAsync(try await adapter.apply(AgentConfigurationRequest(configuration: configuration, mode: .automatic)))
    }

    private func request(mode: ConfigurationMode) -> AgentConfigurationRequest {
        var configuration = AgentConfiguration(
            agent: .codexCLI,
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-test"
        )
        configuration.modelSlots[.sonnet] = "gpt-5-codex"
        configuration.codexReasoningEffort = .custom("turbo")
        return AgentConfigurationRequest(configuration: configuration, mode: mode)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {}
}
