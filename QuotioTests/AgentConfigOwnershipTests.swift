import XCTest
@testable import Quotio

/// Every test here runs against a throwaway home directory. Nothing in this file
/// may read or write the developer's real `~/.claude`, `~/.codex`, `~/.config`
/// or `~/.factory`.
final class AgentConfigOwnershipTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotio-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        try super.tearDownWithError()
    }

    private var verifier: AgentConfigOwnershipVerifier {
        AgentConfigOwnershipVerifier(homeDirectory: home.path)
    }

    private let quotioURL = "http://127.0.0.1:8317"
    private let quotioKey = "quotio-local-6C1E9C0E-6D5E-4C1B-9D0F-2F4B7A0C5E11"

    // MARK: - Receipt storage

    func testReceiptRoundTripsAndNeverStoresTheRawKey() throws {
        let defaults = try makeIsolatedDefaults(#function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = AgentConfigOwnershipStore(defaults: defaults)
        let record = AgentConfigOwnershipRecord(
            agent: .claudeCode,
            baseURL: quotioURL,
            apiKey: quotioKey,
            primaryConfigExisted: true
        )
        store.save(record)

        XCTAssertEqual(store.record(for: .claudeCode), record)
        XCTAssertNil(store.record(for: .codexCLI))

        // The key itself must not be recoverable from UserDefaults.
        let raw = try XCTUnwrap(defaults.data(forKey: AgentConfigOwnershipStore.storageKey))
        let blob = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(blob.contains(quotioKey))
        XCTAssertTrue(blob.contains(record.apiKeyFingerprint))

        store.clear(agent: .claudeCode)
        XCTAssertNil(store.record(for: .claudeCode))
    }

    func testBaseURLNormalisationMatchesTheFormsAgentsStore() {
        let canonical = AgentConfigOwnershipRecord.normalizedBaseURL(quotioURL)
        XCTAssertEqual(AgentConfigOwnershipRecord.normalizedBaseURL("\(quotioURL)/v1"), canonical)
        XCTAssertEqual(AgentConfigOwnershipRecord.normalizedBaseURL("\(quotioURL)/"), canonical)
        XCTAssertEqual(AgentConfigOwnershipRecord.normalizedBaseURL("\(quotioURL)/v1/"), canonical)
    }

    // MARK: - Nothing configured

    func testAgentWithNoConfigOnDiskIsNotOwned() {
        for agent in CLIAgent.allCases {
            XCTAssertEqual(
                verifier.ownership(of: agent, record: nil),
                .notOwned(.notConfigured),
                "\(agent.rawValue) should report notConfigured on an empty home"
            )
        }
    }

    // MARK: - Receipt proves ownership, per agent

    func testReceiptProvesOwnershipForEveryAgent() throws {
        try writeClaudeConfig(baseURL: quotioURL, apiKey: quotioKey)
        try writeCodexConfig(baseURL: quotioURL, apiKey: quotioKey, withCliproxyProvider: true)
        try writeAmpConfig(baseURL: quotioURL, apiKey: quotioKey)
        try writeOpenCodeConfig(baseURL: "\(quotioURL)/v1", apiKey: quotioKey)
        try writeFactoryConfig(entries: [(baseURL: "\(quotioURL)/v1", apiKey: quotioKey)])

        for agent in CLIAgent.allCases {
            let record = AgentConfigOwnershipRecord(
                agent: agent,
                baseURL: quotioURL,
                apiKey: quotioKey,
                primaryConfigExisted: false
            )
            XCTAssertEqual(
                verifier.ownership(of: agent, record: record),
                .owned(.receipt),
                "\(agent.rawValue) should be owned when disk still matches the receipt"
            )
        }
    }

    // MARK: - A different local proxy is not Quotio's

    func testForeignLocalhostProxyIsNeverRevertedWithoutEvidence() throws {
        // A user-run local gateway on localhost, which Quotio never wrote.
        let foreignURL = "http://localhost:4000"
        let foreignKey = "sk-my-own-litellm-key"

        try writeClaudeConfig(baseURL: foreignURL, apiKey: foreignKey)
        try writeAmpConfig(baseURL: foreignURL, apiKey: foreignKey)
        try writeFactoryConfig(entries: [(baseURL: "\(foreignURL)/v1", apiKey: foreignKey)])

        // These three agents carry no Quotio-authored marker, so with no receipt
        // there is nothing to justify touching them.
        for agent in [CLIAgent.claudeCode, .ampCLI, .factoryDroid] {
            XCTAssertEqual(
                verifier.ownership(of: agent, record: nil),
                .notOwned(.noEvidence),
                "\(agent.rawValue) pointing at a foreign local proxy must be left alone"
            )
        }
    }

    func testForeignLocalhostProxyIsNotOwnedEvenWhenAReceiptExistsForAnotherEndpoint() throws {
        try writeClaudeConfig(baseURL: "http://localhost:4000", apiKey: "sk-my-own-litellm-key")

        let record = AgentConfigOwnershipRecord(
            agent: .claudeCode,
            baseURL: quotioURL,
            apiKey: quotioKey,
            primaryConfigExisted: true
        )

        XCTAssertEqual(verifier.ownership(of: .claudeCode, record: record), .notOwned(.externallyModified))
    }

    func testFactoryDroidForeignLocalhostModelIsNotOwnedAlongsideAQuotioReceipt() throws {
        // The default Factory Droid revert path strips *every* localhost custom
        // model. Ownership must be decided per entry, not per host.
        try writeFactoryConfig(entries: [(baseURL: "http://localhost:4000/v1", apiKey: "sk-user-key")])

        let record = AgentConfigOwnershipRecord(
            agent: .factoryDroid,
            baseURL: quotioURL,
            apiKey: quotioKey,
            primaryConfigExisted: true
        )

        XCTAssertEqual(verifier.ownership(of: .factoryDroid, record: record), .notOwned(.externallyModified))
    }

    func testFactoryDroidIsOwnedWhenOneEntryMatchesTheReceipt() throws {
        try writeFactoryConfig(entries: [
            (baseURL: "http://localhost:4000/v1", apiKey: "sk-user-key"),
            (baseURL: "\(quotioURL)/v1", apiKey: quotioKey)
        ])

        let record = AgentConfigOwnershipRecord(
            agent: .factoryDroid,
            baseURL: quotioURL,
            apiKey: quotioKey,
            primaryConfigExisted: true
        )

        XCTAssertEqual(verifier.ownership(of: .factoryDroid, record: record), .owned(.receipt))
    }

    // MARK: - External modification

    func testRotatedAPIKeyMakesTheConfigExternallyModified() throws {
        try writeClaudeConfig(baseURL: quotioURL, apiKey: "user-swapped-this-token")

        let record = AgentConfigOwnershipRecord(
            agent: .claudeCode,
            baseURL: quotioURL,
            apiKey: quotioKey,
            primaryConfigExisted: true
        )

        XCTAssertEqual(verifier.ownership(of: .claudeCode, record: record), .notOwned(.externallyModified))
    }

    func testCodexAuthKeyReplacedOutsideQuotioIsNotOwnedByReceipt() throws {
        // config.toml still points at the proxy but auth.json holds someone
        // else's credential, so the pair no longer matches what Quotio wrote.
        try writeCodexConfig(baseURL: quotioURL, apiKey: "sk-user-openai-key", withCliproxyProvider: true)

        let record = AgentConfigOwnershipRecord(
            agent: .codexCLI,
            baseURL: quotioURL,
            apiKey: quotioKey,
            primaryConfigExisted: true
        )

        XCTAssertEqual(verifier.ownership(of: .codexCLI, record: record), .notOwned(.externallyModified))
    }

    // MARK: - Marker fallback for configs written before receipts existed

    func testCodexCliproxyProviderIsAQuotioAuthoredMarker() throws {
        try writeCodexConfig(baseURL: quotioURL, apiKey: quotioKey, withCliproxyProvider: true)

        XCTAssertEqual(verifier.ownership(of: .codexCLI, record: nil), .owned(.authoredMarker))
    }

    func testCodexWithoutTheCliproxyProviderIsNotOwned() throws {
        try writeCodexConfig(baseURL: "http://localhost:4000", apiKey: "sk-user", withCliproxyProvider: false)

        XCTAssertEqual(verifier.ownership(of: .codexCLI, record: nil), .notOwned(.notConfigured))
    }

    func testOpenCodeQuotioProviderIsAQuotioAuthoredMarker() throws {
        try writeOpenCodeConfig(baseURL: "\(quotioURL)/v1", apiKey: quotioKey)

        XCTAssertEqual(verifier.ownership(of: .openCode, record: nil), .owned(.authoredMarker))
    }

    func testOpenCodeWithOnlyForeignProvidersIsNotOwned() throws {
        let config: [String: Any] = [
            "provider": ["myproxy": ["options": ["baseURL": "http://localhost:4000/v1", "apiKey": "sk-user"]]]
        ]
        try writeJSON(config, to: ".config/opencode/opencode.json")

        XCTAssertEqual(verifier.ownership(of: .openCode, record: nil), .notOwned(.notConfigured))
    }

    // MARK: - Fixtures

    private func writeClaudeConfig(baseURL: String, apiKey: String) throws {
        try writeJSON(
            ["env": ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": apiKey]],
            to: ".claude/settings.json"
        )
    }

    private func writeCodexConfig(baseURL: String, apiKey: String, withCliproxyProvider: Bool) throws {
        let toml: String
        if withCliproxyProvider {
            toml = """
            # CLIProxyAPI Configuration for Codex CLI
            model_provider = "cliproxyapi"
            model = "gpt-5-codex"

            [model_providers.cliproxyapi]
            name = "cliproxyapi"
            base_url = "\(baseURL)"
            wire_api = "responses"
            """
        } else {
            toml = """
            model_provider = "myproxy"
            model = "gpt-5"

            [model_providers.myproxy]
            base_url = "\(baseURL)"
            """
        }
        try write(toml, to: ".codex/config.toml")
        try writeJSON(["OPENAI_API_KEY": apiKey], to: ".codex/auth.json")
    }

    private func writeAmpConfig(baseURL: String, apiKey: String) throws {
        try writeJSON(["amp.url": baseURL], to: ".config/amp/settings.json")
        try writeJSON(["apiKey@\(baseURL)": apiKey], to: ".local/share/amp/secrets.json")
    }

    private func writeOpenCodeConfig(baseURL: String, apiKey: String) throws {
        try writeJSON(
            ["provider": ["quotio": ["name": "Quotio", "options": ["baseURL": baseURL, "apiKey": apiKey]]]],
            to: ".config/opencode/opencode.json"
        )
    }

    private func writeFactoryConfig(entries: [(baseURL: String, apiKey: String)]) throws {
        let models: [[String: Any]] = entries.map {
            ["model": "some-model", "base_url": $0.baseURL, "api_key": $0.apiKey, "provider": "openai"]
        }
        try writeJSON(["custom_models": models], to: ".factory/config.json")
    }

    private func writeJSON(_ object: [String: Any], to relativePath: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try write(String(decoding: data, as: UTF8.self), to: relativePath)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeIsolatedDefaults(_ suiteName: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
