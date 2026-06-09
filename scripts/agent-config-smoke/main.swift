//
//  Agent configuration smoke tests
//

import Foundation

enum SmokeError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeError.failed(message) }
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func makeParentDirectory(for url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
}

func fileContents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

let fileManager = FileManager.default
let home: URL = {
    guard let path = ProcessInfo.processInfo.environment["QUOTIO_AGENT_CONFIG_SMOKE_HOME"], !path.isEmpty else {
        fatalError("QUOTIO_AGENT_CONFIG_SMOKE_HOME is required")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}()

func testReadsNonCodexConfigFixtures() async throws {
    let claudeURL = home.appendingPathComponent(".claude/settings.json")
    try makeParentDirectory(for: claudeURL)
    try writeJSON([
        "env": [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:8171",
            "ANTHROPIC_AUTH_TOKEN": "fixture-auth-value",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "opus-fixture",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "sonnet-fixture",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "haiku-fixture",
            "USER_ENV": "preserve-me"
        ],
        "permissions": ["allow": ["Bash(ls:*)"]]
    ], to: claudeURL)

    let ampURL = home.appendingPathComponent(".config/amp/settings.json")
    try makeParentDirectory(for: ampURL)
    try writeJSON(["amp.url": "http://localhost:8171"], to: ampURL)

    let openCodeURL = home.appendingPathComponent(".config/opencode/opencode.json")
    try makeParentDirectory(for: openCodeURL)
    try writeJSON([
        "provider": [
            "quotio": [
                "options": [
                    "baseURL": "http://127.0.0.1:8171/v1",
                    "apiKey": "fixture-api-value"
                ]
            ]
        ]
    ], to: openCodeURL)

    let factoryURL = home.appendingPathComponent(".factory/config.json")
    try makeParentDirectory(for: factoryURL)
    try writeJSON([
        "custom_models": [[
            "base_url": "http://localhost:8171/v1",
            "api_key": "factory-fixture-value"
        ]]
    ], to: factoryURL)

    let service = AgentConfigurationService(homeDirectory: home)

    guard let claude = await service.readConfiguration(agent: .claudeCode) else {
        throw SmokeError.failed("Claude fixture was not read")
    }
    try expect(claude.isProxyConfigured, "Claude proxy config was not detected")
    try expect(claude.modelSlots[.opus] == "opus-fixture", "Claude opus model was not read")
    try expect(claude.modelSlots[.sonnet] == "sonnet-fixture", "Claude sonnet model was not read")
    try expect(claude.modelSlots[.haiku] == "haiku-fixture", "Claude haiku model was not read")

    guard let amp = await service.readConfiguration(agent: .ampCLI) else {
        throw SmokeError.failed("Amp fixture was not read")
    }
    try expect(amp.baseURL == "http://localhost:8171", "Amp base URL was not read")
    try expect(amp.isProxyConfigured, "Amp proxy config was not detected")

    guard let openCode = await service.readConfiguration(agent: .openCode) else {
        throw SmokeError.failed("OpenCode fixture was not read")
    }
    try expect(openCode.baseURL == "http://127.0.0.1:8171/v1", "OpenCode base URL was not read")
    try expect(openCode.apiKey == "fixture-api-value", "OpenCode API value was not read")
    try expect(openCode.isProxyConfigured, "OpenCode proxy config was not detected")

    guard let factory = await service.readConfiguration(agent: .factoryDroid) else {
        throw SmokeError.failed("Factory Droid fixture was not read")
    }
    try expect(factory.baseURL == "http://localhost:8171/v1", "Factory Droid base URL was not read")
    try expect(factory.apiKey == "factory-fixture-value", "Factory Droid API value was not read")
    try expect(factory.isProxyConfigured, "Factory Droid proxy config was not detected")
}

func testBackupListingAndRestorePreserveCurrentConfig() async throws {
    let settingsURL = home.appendingPathComponent(".config/amp/settings.json")
    try makeParentDirectory(for: settingsURL)
    try #"{"amp.url":"http://current.local"}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

    let backupURL = home.appendingPathComponent(".config/amp/settings.json.backup.1736840000")
    try #"{"amp.url":"http://backup.local"}"#.write(to: backupURL, atomically: true, encoding: .utf8)

    let service = AgentConfigurationService(homeDirectory: home)
    let backups = await service.listBackups(agent: .ampCLI)
    try expect(backups.count == 1, "Expected one Amp backup, found \(backups.count)")

    try await service.restoreFromBackup(backups[0])

    let restored = try fileContents(settingsURL)
    try expect(restored.contains("http://backup.local"), "Backup content was not restored")

    let postRestoreBackups = await service.listBackups(agent: .ampCLI)
    try expect(postRestoreBackups.count == 2, "Restore should preserve current config in a new backup")
    try expect(
        postRestoreBackups.contains { backup in
            (try? fileContents(URL(fileURLWithPath: backup.path)).contains("http://current.local")) == true
        },
        "Current config was not backed up before restore"
    )
}

try await testReadsNonCodexConfigFixtures()
try await testBackupListingAndRestorePreserveCurrentConfig()
print("AgentConfigurationService smoke tests passed")
