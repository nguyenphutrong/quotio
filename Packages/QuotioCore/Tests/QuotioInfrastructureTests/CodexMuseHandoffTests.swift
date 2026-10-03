import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

/// What Codex needs before it can reach a model through the proxy at all. Both facts below
/// were read from a live run: without the bearer token the proxy answers
/// `401 {"error":"Missing API key"}`, and without the model metadata Meta's Muse endpoint
/// rejects the request over the tools Codex declares for an unknown model.
final class CodexMuseHandoffTests: XCTestCase {
    func testTheManagedBlockCarriesTheKeyCodexWillActuallySend() throws {
        let toml = CodexConfigurationCodec.managedTOML(
            model: "muse-spark-1.3",
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-local-key",
            catalogPath: "/Users/someone/.codex/quotio-proxy-catalog.json"
        )

        XCTAssertTrue(toml.contains(#"experimental_bearer_token = "quotio-local-key""#))
        XCTAssertTrue(toml.contains(#"model_catalog_json = "/Users/someone/.codex/quotio-proxy-catalog.json""#))
        XCTAssertTrue(toml.contains(#"wire_api = "responses""#))
    }

    func testRevertingTakesBothOfThemBackOut() throws {
        let existing = CodexConfigurationCodec.managedTOML(
            model: "muse-spark-1.3",
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-local-key",
            catalogPath: "/Users/someone/.codex/quotio-proxy-catalog.json"
        ) + "\n[profiles.work]\nmodel = \"kept\"\n"

        let reverted = CodexConfigurationCodec.removingManagedTOML(from: existing)

        XCTAssertFalse(reverted.contains("experimental_bearer_token"))
        XCTAssertFalse(reverted.contains("model_catalog_json"))
        XCTAssertFalse(reverted.contains("cliproxyapi"))
        XCTAssertTrue(reverted.contains("[profiles.work]"), "the user's own configuration stays")
    }

    func testRevertingLeavesSomebodyElsesCatalogAlone() throws {
        let existing = """
        model_catalog_json = "/Users/someone/.codex/opencodex-catalog.json"

        """ + CodexConfigurationCodec.managedTOML(
            model: "muse-spark-1.3",
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-local-key",
            catalogPath: "/Users/someone/.codex/quotio-proxy-catalog.json"
        )

        let reverted = CodexConfigurationCodec.removingManagedTOML(from: existing)

        XCTAssertTrue(reverted.contains("opencodex-catalog.json"))
        XCTAssertFalse(reverted.contains("quotio-proxy-catalog.json"))
    }

    func testTheCatalogDeclaresNeitherToolMuseRefuses() throws {
        let entries = try models(in: CodexModelCatalog.json(models: ["muse-spark-1.3"]))

        let entry = try XCTUnwrap(entries.first)
        XCTAssertNil(
            entry["apply_patch_tool_type"],
            "the freeform apply_patch is a `custom` tool, which Muse refuses outright")
        XCTAssertEqual(
            entry["supports_search_tool"] as? Bool, false,
            "the hosted search tool is sent with search_content_types, which Muse refuses")
        XCTAssertNil(entry["web_search_tool_type"])
        XCTAssertEqual(entry["slug"] as? String, "muse-spark-1.3")
    }

    func testOnlyMuseClaimsItsOwnContextWindow() throws {
        let entries = try models(in: CodexModelCatalog.json(models: ["muse-spark-1.3", "claude-opus-5"]))

        let bySlug = Dictionary(uniqueKeysWithValues: entries.map { ($0["slug"] as? String ?? "", $0) })
        XCTAssertEqual(bySlug["muse-spark-1.3"]?["context_window"] as? Int, 1_048_576)
        XCTAssertEqual(
            bySlug["claude-opus-5"]?["context_window"] as? Int, 128_000,
            "a window claimed larger than the model's makes Codex compact too late")
    }

    func testApplyWritesTheCatalogForEveryModelTheProxyServes() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-muse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = CodexAgentConfigurationAdapter(fileStore: AgentFileStore(homeDirectory: home.path))
        var configuration = AgentConfiguration(
            agent: .codexCLI,
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-local-key"
        )
        configuration.modelSlots[.sonnet] = "muse-spark-1.3"

        _ = try await adapter.apply(
            AgentConfigurationRequest(
                configuration: configuration,
                mode: .automatic,
                availableModels: [
                    AvailableModel(id: "muse-spark-1.3", name: "muse-spark-1.3", provider: "meta", isDefault: false),
                    AvailableModel(id: "claude-opus-5", name: "claude-opus-5", provider: "anthropic", isDefault: false),
                ]
            )
        )

        let catalogURL = home.appendingPathComponent(".codex/\(CodexModelCatalog.fileName)")
        let slugs = try models(in: Data(contentsOf: catalogURL)).compactMap { $0["slug"] as? String }
        XCTAssertEqual(slugs.sorted(), ["claude-opus-5", "muse-spark-1.3"])
        let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains(catalogURL.path))
        XCTAssertTrue(config.contains(#"experimental_bearer_token = "quotio-local-key""#))
    }

    /// config.toml now carries the proxy's API key, so it must not be left readable by
    /// other accounts on the machine the way a fresh file otherwise would be.
    func testTheConfigCarryingTheKeyIsWrittenOwnerOnly() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-perms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = CodexAgentConfigurationAdapter(fileStore: AgentFileStore(homeDirectory: home.path))
        var configuration = AgentConfiguration(
            agent: .codexCLI,
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-local-key"
        )
        configuration.modelSlots[.sonnet] = "muse-spark-1.3"

        _ = try await adapter.apply(AgentConfigurationRequest(configuration: configuration, mode: .automatic))

        let config = home.appendingPathComponent(".codex/config.toml")
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testWithoutARosterTheCatalogStillCoversTheModelBeingConfigured() throws {
        let entries = try models(in: CodexModelCatalog.json(models: ["muse-spark-1.3"]))
        XCTAssertEqual(entries.count, 1)
    }

    private func models(in data: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["models"] as? [[String: Any]])
    }
}
