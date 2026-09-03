import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class AgentConfigurationAdaptersTests: XCTestCase {
    func testAdaptersReturnSemanticInstructions() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentFileStore(homeDirectory: home.path)

        let claude = try await ClaudeCodeAgentConfigurationAdapter(fileStore: store)
            .preview(request(agent: .claudeCode, mode: .manual))
        let codex = try await CodexAgentConfigurationAdapter(fileStore: store)
            .preview(request(agent: .codexCLI, mode: .manual))
        let amp = try await AmpAgentConfigurationAdapter(fileStore: store)
            .preview(request(agent: .ampCLI, mode: .manual))
        let openCode = try await OpenCodeAgentConfigurationAdapter(fileStore: store)
            .preview(request(agent: .openCode, mode: .manual))
        let factoryDroid = try await FactoryDroidAgentConfigurationAdapter(fileStore: store)
            .preview(request(agent: .factoryDroid, mode: .manual))

        XCTAssertEqual(claude.instructions, .claudeChooseManualOption)
        XCTAssertEqual(codex.instructions, .codexMergeAndSaveFiles)
        XCTAssertEqual(amp.instructions, .ampMergeAndSaveFiles)
        XCTAssertEqual(openCode.instructions, .openCodeMergeManualConfig)
        XCTAssertEqual(factoryDroid.instructions, .factoryDroidSaveManualConfig)
        XCTAssertEqual(amp.rawConfigs.map(\.instructions), [
            .ampMergeSettings,
            .ampMergeSecrets,
            .ampUseEnvironmentVariables,
        ])
    }

    func testClaudeApplyPreservesUnknownSettingsAndPermissions() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try writeJSON([
            "permissions": ["allow": ["Read"]],
            "env": ["USER_FLAG": "keep"],
        ], to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: settings.path)
        let adapter = ClaudeCodeAgentConfigurationAdapter(
            fileStore: AgentFileStore(homeDirectory: home.path)
        )

        let result = try await adapter.apply(request(agent: .claudeCode, mode: .automatic))

        XCTAssertTrue(result.success)
        let object = try json(at: settings)
        XCTAssertEqual((object["permissions"] as? [String: Any])?["allow"] as? [String], ["Read"])
        let environment = try XCTUnwrap(object["env"] as? [String: String])
        XCTAssertEqual(environment["USER_FLAG"], "keep")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "quotio-key")
        let permissions = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
        let savedConfiguration = await adapter.inspect()
        XCTAssertTrue(try XCTUnwrap(savedConfiguration).isProxyConfigured)
    }

    func testClaudeMalformedInputIsNotMutatedOrBackedUp() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        let malformed = Data("{ malformed".utf8)
        try write(malformed, to: settings)
        let adapter = ClaudeCodeAgentConfigurationAdapter(
            fileStore: AgentFileStore(homeDirectory: home.path)
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.apply(request(agent: .claudeCode, mode: .automatic))
        )

        XCTAssertEqual(try Data(contentsOf: settings), malformed)
        let backups = await adapter.listBackups()
        XCTAssertTrue(backups.isEmpty)
    }

    func testAmpApplyPreservesNativeSecretsAndRollsBackBothFiles() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".config/amp/settings.json")
        let secrets = home.appendingPathComponent(".local/share/amp/secrets.json")
        let oldSettings = try JSONSerialization.data(withJSONObject: ["theme": "dark"])
        let oldSecrets = try JSONSerialization.data(withJSONObject: [
            "apiKey@https://ampcode.com/": "native-token",
            "unrelated": "keep",
        ])
        try write(oldSettings, to: settings)
        try write(oldSecrets, to: secrets)
        let store = AgentFileStore(homeDirectory: home.path, beforeWrite: { _, index in
            if index == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        let adapter = AmpAgentConfigurationAdapter(fileStore: store)

        await XCTAssertThrowsErrorAsync(
            try await adapter.apply(request(agent: .ampCLI, mode: .automatic))
        )

        XCTAssertEqual(try Data(contentsOf: settings), oldSettings)
        XCTAssertEqual(try Data(contentsOf: secrets), oldSecrets)

        let workingAdapter = AmpAgentConfigurationAdapter(
            fileStore: AgentFileStore(homeDirectory: home.path)
        )
        _ = try await workingAdapter.apply(request(agent: .ampCLI, mode: .automatic))
        let mergedSecrets = try json(at: secrets)
        XCTAssertEqual(mergedSecrets["apiKey@https://ampcode.com/"] as? String, "native-token")
        XCTAssertEqual(mergedSecrets["unrelated"] as? String, "keep")
        XCTAssertEqual(mergedSecrets["apiKey@http://127.0.0.1:8317"] as? String, "quotio-key")
    }

    func testFactoryApplyAndResetPreserveUnknownKeysAndRemoteModels() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".factory/config.json")
        try writeJSON([
            "theme": "dark",
            "custom_models": [
                ["model": "remote", "base_url": "https://example.com/v1", "custom": true],
                ["model": "old-local", "base_url": "http://localhost:8317/v1"],
            ],
        ], to: config)
        let adapter = FactoryDroidAgentConfigurationAdapter(
            fileStore: AgentFileStore(homeDirectory: home.path)
        )
        let model = AvailableModel(id: "new", name: "new-local", provider: "openai", isDefault: false)

        _ = try await adapter.apply(request(
            agent: .factoryDroid,
            mode: .automatic,
            availableModels: [model]
        ))

        var object = try json(at: config)
        XCTAssertEqual(object["theme"] as? String, "dark")
        var models = try XCTUnwrap(object["custom_models"] as? [[String: Any]])
        XCTAssertEqual(models.map { $0["model"] as? String }, ["remote", "new-local"])
        XCTAssertEqual(models.first?["custom"] as? Bool, true)

        _ = try await adapter.reset(mode: .automatic)
        object = try json(at: config)
        models = try XCTUnwrap(object["custom_models"] as? [[String: Any]])
        XCTAssertEqual(models.map { $0["model"] as? String }, ["remote"])
        XCTAssertEqual(object["theme"] as? String, "dark")
    }

    func testFileStoreRefusesConfigurationAndBackupSymlinks() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("target.json")
        let link = home.appendingPathComponent("settings.json")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = AgentFileStore(homeDirectory: home.path)

        let linkedData = await store.data(at: link.path)
        XCTAssertNil(linkedData)
        do {
            _ = try await store.apply([AgentFileWrite(path: link.path, data: Data("changed".utf8))])
            XCTFail("Expected symlink refusal")
        } catch {
            XCTAssertEqual(error as? AgentFileStoreError, .symbolicLinkRefused(link.path))
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")

        let backupLink = home.appendingPathComponent("settings.json.backup.1")
        try FileManager.default.createSymbolicLink(at: backupLink, withDestinationURL: target)
        let backup = AgentBackupFile(
            path: backupLink.path,
            timestamp: Date(timeIntervalSince1970: 1),
            agent: .claudeCode
        )
        do {
            try await store.restore(backup)
            XCTFail("Expected backup symlink refusal")
        } catch {
            XCTAssertEqual(error as? AgentFileStoreError, .symbolicLinkRefused(backupLink.path))
        }
    }

    func testEveryAdapterRejectsRequestsAndBackupsForAnotherAgent() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AgentFileStore(homeDirectory: home.path)
        let adapters: [any AgentConfigurationRepository] = [
            ClaudeCodeAgentConfigurationAdapter(fileStore: store),
            CodexAgentConfigurationAdapter(fileStore: store),
            AmpAgentConfigurationAdapter(fileStore: store),
            OpenCodeAgentConfigurationAdapter(fileStore: store),
            FactoryDroidAgentConfigurationAdapter(fileStore: store),
        ]

        for adapter in adapters {
            let otherAgent = adapter.agent == .claudeCode ? CLIAgent.codexCLI : .claudeCode
            await XCTAssertThrowsErrorAsync(
                try await adapter.apply(request(agent: otherAgent, mode: .automatic))
            )
            let backup = AgentBackupFile(
                path: "/tmp/config.backup.1",
                timestamp: Date(timeIntervalSince1970: 1),
                agent: otherAgent
            )
            await XCTAssertThrowsErrorAsync(try await adapter.restore(backup))
        }
    }

    private func request(
        agent: CLIAgent,
        mode: ConfigurationMode,
        availableModels: [AvailableModel] = []
    ) -> AgentConfigurationRequest {
        AgentConfigurationRequest(
            configuration: AgentConfiguration(
                agent: agent,
                proxyURL: "http://127.0.0.1:8317/v1",
                apiKey: "quotio-key"
            ),
            mode: mode,
            storageOption: .jsonOnly,
            availableModels: availableModels
        )
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-adapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try write(try JSONSerialization.data(withJSONObject: object), to: url)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {}
}
