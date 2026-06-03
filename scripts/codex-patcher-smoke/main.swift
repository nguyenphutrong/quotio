//
//  Codex patcher smoke tests
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

func tempDirectory(named name: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("quotio-codex-patcher-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func makeConfig(proxyURL: String = "http://127.0.0.1:8171/v1") -> AgentConfiguration {
    var config = AgentConfiguration(
        agent: .codexCLI,
        proxyURL: proxyURL,
        apiKey: "secret-token"
    )
    config.modelSlots[.sonnet] = "gpt-5-codex"
    return config
}

let models = [
    AvailableModel(id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai", isDefault: false),
    AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "google", isDefault: false)
]

func testInstallRestoreAndIdempotency() throws {
    let home = try tempDirectory(named: "home")
    let runtime = try tempDirectory(named: "runtime")
    let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let configURL = codexDir.appendingPathComponent("config.toml")
    try """
    model = "gpt-5"
    model_provider = "openai"
    model_catalog_json = "/tmp/catalog.json"
    model_reasoning_effort = "medium"

    [profiles.dev]
    model = "profile-model"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let patcher = CodexConfigPatcher(homeDirectory: home, runtimeDirectory: runtime)
    let prepared = try patcher.makePreparedConfig(config: makeConfig(), availableModels: models)
    try expect(prepared.configTOML.contains("model_provider = \"quotio\""), "missing quotio provider")
    try expect(prepared.configTOML.contains("[model_providers.quotio]"), "missing quotio provider section")
    try expect(prepared.configTOML.contains("model_catalog_json = \"\(runtime.path)/custom_model_catalog.json\""), "missing catalog path")
    try expect(prepared.configTOML.contains("experimental_bearer_token = \"secret-token\""), "missing bearer token")
    try expect(prepared.catalogJSON.contains("\"slug\" : \"gpt-5-codex\""), "missing catalog model")

    _ = try patcher.install(prepared)
    _ = try patcher.install(try patcher.makePreparedConfig(config: makeConfig(), availableModels: models))

    let installed = try String(contentsOf: configURL, encoding: .utf8)
    try expect(installed.components(separatedBy: "[model_providers.quotio]").count == 2, "install is not idempotent")
    try expect(installed.contains("[profiles.dev]\nmodel = \"profile-model\""), "profile model was not preserved")

    try patcher.switchActiveModel(to: "gemini-3-pro-preview")
    let switched = try String(contentsOf: configURL, encoding: .utf8)
    try expect(switched.contains("model = \"gemini-3-pro-preview\""), "model switch failed")
    try expect(switched.contains("name = \"Quotio\""), "provider label should remain Quotio")

    _ = try patcher.restoreDefaultConfig()
    let restored = try String(contentsOf: configURL, encoding: .utf8)
    try expect(restored.contains("model_provider = \"openai\""), "previous provider was not restored")
    try expect(restored.contains("model_reasoning_effort = \"medium\""), "reasoning effort was not restored")
    try expect(!restored.contains("[model_providers.quotio]"), "quotio provider was not removed")
}

func testLegacyCliproxyapiDoesNotRestoreAsUserConfig() throws {
    let home = try tempDirectory(named: "home")
    let runtime = try tempDirectory(named: "runtime")
    let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let configURL = codexDir.appendingPathComponent("config.toml")
    try """
    model = "old-proxy-model"
    model_provider = "cliproxyapi"

    [model_providers.cliproxyapi]
    name = "cliproxyapi"
    base_url = "http://127.0.0.1:8171/v1"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let patcher = CodexConfigPatcher(homeDirectory: home, runtimeDirectory: runtime)
    _ = try patcher.install(try patcher.makePreparedConfig(config: makeConfig(), availableModels: models))
    _ = try patcher.restoreDefaultConfig()

    let restored = try String(contentsOf: configURL, encoding: .utf8)
    try expect(!restored.contains("cliproxyapi"), "legacy provider was restored instead of cleaned")
}

func testHashInQuotedTOMLValueIsPreserved() throws {
    let home = try tempDirectory(named: "home")
    let runtime = try tempDirectory(named: "runtime")
    let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let configURL = codexDir.appendingPathComponent("config.toml")
    try """
    model = "gpt-5"
    model_provider = "openai#team"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let patcher = CodexConfigPatcher(homeDirectory: home, runtimeDirectory: runtime)
    _ = try patcher.install(try patcher.makePreparedConfig(config: makeConfig(), availableModels: models))
    _ = try patcher.restoreDefaultConfig()

    let restored = try String(contentsOf: configURL, encoding: .utf8)
    try expect(restored.contains("model_provider = \"openai#team\""), "quoted hash value was truncated")
}

func testMalformedManagedBlockFailsClosed() throws {
    let home = try tempDirectory(named: "home")
    let runtime = try tempDirectory(named: "runtime")
    let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let configURL = codexDir.appendingPathComponent("config.toml")
    try """
    # >>> quotio codex managed >>>
    model = "broken"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let patcher = CodexConfigPatcher(homeDirectory: home, runtimeDirectory: runtime)

    do {
        _ = try patcher.makePreparedConfig(config: makeConfig(), availableModels: models)
        throw SmokeError.failed("malformed managed block did not throw")
    } catch CodexConfigPatcher.PatcherError.malformedManagedBlock {
    }
}

try testInstallRestoreAndIdempotency()
try testLegacyCliproxyapiDoesNotRestoreAsUserConfig()
try testHashInQuotedTOMLValueIsPreserved()
try testMalformedManagedBlockFailsClosed()
print("CodexConfigPatcher smoke tests passed")
