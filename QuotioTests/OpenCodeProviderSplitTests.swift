import XCTest
@testable import Quotio

final class OpenCodeProviderSplitTests: XCTestCase {

    private let apiKey = "quotio-local-test"
    private let baseURL = "http://127.0.0.1:8317"

    private let mixedModels: [AvailableModel] = [
        AvailableModel(id: "gemini-claude-opus-4-6-thinking", name: "gemini-claude-opus-4-6-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5", name: "gemini-claude-sonnet-4-5", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", provider: "google", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false)
    ]

    // MARK: - isOpenCodeGeminiNativeModel

    func testGeminiNativeModelsAreDetected() {
        XCTAssertTrue(AgentConfigurationService.isOpenCodeGeminiNativeModel("gemini-3-pro-preview"))
        XCTAssertTrue(AgentConfigurationService.isOpenCodeGeminiNativeModel("gemini-3-flash-preview"))
        XCTAssertTrue(AgentConfigurationService.isOpenCodeGeminiNativeModel("gemini-2.5-flash"))
        XCTAssertTrue(AgentConfigurationService.isOpenCodeGeminiNativeModel("gemini-2.5-computer-use-preview-10-2025"))
    }

    func testAntigravityClaudeModelsStayOnAnthropicProtocol() {
        XCTAssertFalse(AgentConfigurationService.isOpenCodeGeminiNativeModel("gemini-claude-opus-4-6-thinking"))
        XCTAssertFalse(AgentConfigurationService.isOpenCodeGeminiNativeModel("gemini-claude-sonnet-4-5"))
        XCTAssertFalse(AgentConfigurationService.isOpenCodeGeminiNativeModel("claude-sonnet-4-5"))
    }

    func testNonGeminiModelsAreNotGeminiNative() {
        XCTAssertFalse(AgentConfigurationService.isOpenCodeGeminiNativeModel("gpt-5.1-codex"))
        XCTAssertFalse(AgentConfigurationService.isOpenCodeGeminiNativeModel("qwen3-coder-plus"))
    }

    // MARK: - openCodeQuotioProviderEntries

    func testMixedModelsProduceTwoProviders() throws {
        let entries = AgentConfigurationService.openCodeQuotioProviderEntries(
            models: mixedModels,
            apiKey: apiKey,
            baseURL: baseURL
        )

        XCTAssertEqual(Set(entries.keys), ["quotio", "quotio-gemini"])

        let quotio = try XCTUnwrap(entries["quotio"])
        XCTAssertEqual(quotio["npm"] as? String, "@ai-sdk/anthropic")
        let quotioOptions = try XCTUnwrap(quotio["options"] as? [String: Any])
        XCTAssertEqual(quotioOptions["baseURL"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(quotioOptions["apiKey"] as? String, apiKey)
        XCTAssertEqual(quotioOptions["litellmProxy"] as? Bool, true)
        let quotioModels = try XCTUnwrap(quotio["models"] as? [String: Any])
        XCTAssertEqual(Set(quotioModels.keys), [
            "gemini-claude-opus-4-6-thinking",
            "gemini-claude-sonnet-4-5",
            "gpt-5.1-codex"
        ])

        let gemini = try XCTUnwrap(entries["quotio-gemini"])
        XCTAssertEqual(gemini["npm"] as? String, "@ai-sdk/google")
        XCTAssertEqual(gemini["name"] as? String, "Quotio (Gemini)")
        let geminiOptions = try XCTUnwrap(gemini["options"] as? [String: Any])
        XCTAssertEqual(geminiOptions["baseURL"] as? String, "http://127.0.0.1:8317/v1beta")
        XCTAssertEqual(geminiOptions["apiKey"] as? String, apiKey)
        XCTAssertNil(geminiOptions["litellmProxy"], "Anthropic-specific option must not leak into the Google provider")
        let geminiModels = try XCTUnwrap(gemini["models"] as? [String: Any])
        XCTAssertEqual(Set(geminiModels.keys), ["gemini-3-pro-preview", "gemini-2.5-flash"])
    }

    func testNoGeminiModelsProducesSingleProviderAsBefore() throws {
        let models = [
            AvailableModel(id: "gemini-claude-sonnet-4-5", name: "gemini-claude-sonnet-4-5", provider: "anthropic", isDefault: false),
            AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false)
        ]

        let entries = AgentConfigurationService.openCodeQuotioProviderEntries(
            models: models,
            apiKey: apiKey,
            baseURL: baseURL
        )

        XCTAssertEqual(Set(entries.keys), ["quotio"])
        let quotio = try XCTUnwrap(entries["quotio"])
        let quotioModels = try XCTUnwrap(quotio["models"] as? [String: Any])
        XCTAssertEqual(Set(quotioModels.keys), ["gemini-claude-sonnet-4-5", "gpt-5.1-codex"])
    }

    func testDefaultModelCatalogSplitsIntoBothProviders() throws {
        let entries = AgentConfigurationService.openCodeQuotioProviderEntries(
            models: AvailableModel.allModels,
            apiKey: apiKey,
            baseURL: baseURL
        )

        XCTAssertEqual(Set(entries.keys), ["quotio", "quotio-gemini"])
        let quotioModels = try XCTUnwrap(entries["quotio"]?["models"] as? [String: Any])
        let geminiModels = try XCTUnwrap(entries["quotio-gemini"]?["models"] as? [String: Any])
        XCTAssertEqual(quotioModels.count + geminiModels.count, AvailableModel.allModels.count)
        XCTAssertTrue(geminiModels.keys.allSatisfy { $0.contains("gemini") && !$0.contains("claude") })
        XCTAssertTrue(quotioModels.keys.contains("gemini-claude-opus-4-6-thinking"))
        XCTAssertFalse(quotioModels.keys.contains("gemini-3-pro-preview"))
    }

    // MARK: - openCodeProvidersApplyingQuotioEntries

    func testApplyingEntriesPreservesUserProviders() throws {
        let existing: [String: Any] = [
            "myrouter": ["npm": "@ai-sdk/openai-compatible"],
            "quotio": ["options": ["apiKey": "stale-key"]]
        ]

        let entries = AgentConfigurationService.openCodeQuotioProviderEntries(
            models: mixedModels,
            apiKey: apiKey,
            baseURL: baseURL
        )
        let updated = AgentConfigurationService.openCodeProvidersApplyingQuotioEntries(existing, entries: entries)

        XCTAssertNotNil(updated["myrouter"], "User-defined provider must survive")
        let quotio = try XCTUnwrap(updated["quotio"] as? [String: Any])
        let options = try XCTUnwrap(quotio["options"] as? [String: Any])
        XCTAssertEqual(options["apiKey"] as? String, apiKey, "Stale quotio entry must be replaced")
        XCTAssertNotNil(updated["quotio-gemini"])
    }

    func testApplyingEntriesRemovesStaleGeminiProviderWhenNoGeminiModelsRemain() {
        let existing: [String: Any] = [
            "quotio": ["name": "Quotio"],
            "quotio-gemini": ["name": "Quotio (Gemini)"],
            "myrouter": ["npm": "@ai-sdk/openai-compatible"]
        ]

        let entries = AgentConfigurationService.openCodeQuotioProviderEntries(
            models: [AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false)],
            apiKey: apiKey,
            baseURL: baseURL
        )
        let updated = AgentConfigurationService.openCodeProvidersApplyingQuotioEntries(existing, entries: entries)

        XCTAssertNil(updated["quotio-gemini"], "Stale Quotio-managed Gemini provider must be removed")
        XCTAssertNotNil(updated["quotio"])
        XCTAssertNotNil(updated["myrouter"])
    }

    // MARK: - openCodeConfigRemovingQuotioProviders

    func testRevertRemovesBothQuotioManagedProviders() throws {
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "theme": "dark",
            "provider": [
                "quotio": ["name": "Quotio"],
                "quotio-gemini": ["name": "Quotio (Gemini)"],
                "myrouter": ["npm": "@ai-sdk/openai-compatible"]
            ]
        ]

        let updated = AgentConfigurationService.openCodeConfigRemovingQuotioProviders(config)

        XCTAssertEqual(updated["theme"] as? String, "dark")
        let providers = try XCTUnwrap(updated["provider"] as? [String: Any])
        XCTAssertNil(providers["quotio"])
        XCTAssertNil(providers["quotio-gemini"])
        XCTAssertNotNil(providers["myrouter"])
    }

    func testRevertDropsEmptyProviderObject() {
        let config: [String: Any] = [
            "theme": "dark",
            "provider": [
                "quotio": ["name": "Quotio"],
                "quotio-gemini": ["name": "Quotio (Gemini)"]
            ]
        ]

        let updated = AgentConfigurationService.openCodeConfigRemovingQuotioProviders(config)

        XCTAssertEqual(updated["theme"] as? String, "dark")
        XCTAssertNil(updated["provider"])
    }

    func testRevertLeavesConfigWithoutProvidersUntouched() {
        let config: [String: Any] = ["theme": "dark"]

        let updated = AgentConfigurationService.openCodeConfigRemovingQuotioProviders(config)

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated["theme"] as? String, "dark")
    }
}
