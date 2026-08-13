import XCTest
@testable import Quotio

@MainActor
final class RequestLogProviderTests: XCTestCase {

    // MARK: - Protocol Detection

    func testProtocolDetectionSeparatesProtocolFromProvider() {
        XCTAssertEqual(RequestProtocol.detect(fromPath: "/v1/chat/completions"), .openai)
        XCTAssertEqual(RequestProtocol.detect(fromPath: "/v1/responses"), .openai)
        XCTAssertEqual(RequestProtocol.detect(fromPath: "/v1/messages"), .anthropic)
        XCTAssertEqual(RequestProtocol.detect(fromPath: "/anthropic/v1/messages"), .anthropic)
        XCTAssertEqual(
            RequestProtocol.detect(fromPath: "/v1beta/models/gemini-2.5-pro:generateContent"),
            .gemini
        )
        // A Gemini path embeds the model id; it must not be read as the Anthropic protocol.
        XCTAssertEqual(
            RequestProtocol.detect(fromPath: "/v1beta/models/claude-sonnet-4-5:generateContent"),
            .gemini
        )
        XCTAssertNil(RequestProtocol.detect(fromPath: "/v1/models"))
    }

    // MARK: - Endpoint + Model Combinations (capture time)

    /// The reviewer's scenario: OpenAI-compatible endpoints are shared, so the model decides.
    func testOpenAICompatibleEndpointUsesModelFamilyNotProtocol() {
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "qwen3-coder-plus"), "qwen")
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "glm-4.6"), "glm")
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "grok-4"), "grok")
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "deepseek-chat"), "deepseek")
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "kimi-k3"), "kimi")
    }

    func testGenuineOpenAIRequestsStillReadAsOpenAI() {
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "gpt-5.2"), "openai")
        XCTAssertEqual(deriveProvider(path: "/v1/responses", model: "gpt-5.1-codex"), "openai")
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "o3-mini"), "openai")
    }

    func testAnthropicAndGeminiEndpoints() {
        XCTAssertEqual(deriveProvider(path: "/v1/messages", model: "claude-sonnet-4-5"), "claude")
        XCTAssertEqual(
            deriveProvider(path: "/v1beta/models/gemini-2.5-pro:generateContent", model: nil),
            "gemini"
        )
    }

    /// Aggregators serve other vendors' model families, so a provider-scoped path outranks
    /// the model name (the reviewer's Copilot / Antigravity caveat).
    func testHostingAggregatorInPathOutranksModelFamily() {
        XCTAssertEqual(
            deriveProvider(path: "/copilot/v1/chat/completions", model: "claude-3.5-sonnet"),
            AIProvider.copilot.rawValue
        )
        XCTAssertEqual(
            deriveProvider(path: "/kiro/v1/messages", model: "claude-sonnet-4-5"),
            AIProvider.kiro.rawValue
        )
    }

    /// Antigravity hosts Claude under a `gemini-claude-` prefix
    /// (Quotio/Models/AgentModels.swift, Quotio/Views/Components/FallbackSheets.swift).
    func testAntigravityHostedClaudeModelIsNotReportedAsClaude() {
        XCTAssertEqual(
            deriveProvider(path: "/v1/chat/completions", model: "gemini-claude-opus-4-6-thinking"),
            AIProvider.antigravity.rawValue
        )
    }

    /// ClinePass model ids are namespaced (Quotio/Views/Components/CustomProviderSheet.swift).
    func testClinePassHostedModelsResolveToTheAggregator() {
        XCTAssertEqual(
            deriveProvider(path: "/v1/chat/completions", model: "cline-pass/qwen3.7-max"),
            AIProvider.clinePass.rawValue
        )
        XCTAssertEqual(
            deriveProvider(path: "/v1/chat/completions", model: "cline-pass/deepseek-v4-pro"),
            AIProvider.clinePass.rawValue
        )
    }

    /// When the model family is unknown the protocol label is the best available answer,
    /// which keeps behaviour identical to the previous release for those rows.
    func testUnknownModelFallsBackToProtocolLabel() {
        XCTAssertEqual(deriveProvider(path: "/v1/chat/completions", model: "totally-unknown"), "openai")
        XCTAssertEqual(deriveProvider(path: "/v1/messages", model: nil), "claude")
        XCTAssertNil(deriveProvider(path: "/v1/models", model: nil))
    }

    // MARK: - Model Name Inference

    func testInferProviderFromClaudeModels() {
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "claude-sonnet-4-5"), "claude")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "claude-opus-4-5"), "claude")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "Claude-Haiku-4-5"), "claude")
    }

    func testInferProviderFromKiroModelsBeforeClaude() {
        // Kiro-resolved models embed a Claude model name and must still map to kiro
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "kiro-claude-opus-4-5-agentic"), "kiro")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "codewhisperer-model"), "kiro")
    }

    func testInferProviderFromGeminiModels() {
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "gemini-2.5-pro"), "gemini")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "models/gemini-2.0-flash"), "gemini")
    }

    func testInferProviderFromOpenAIModels() {
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "gpt-5.2"), "openai")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "o3-mini"), "openai")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "gpt-5.1-codex"), "openai")
    }

    func testInferProviderFromOtherModelFamilies() {
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "qwen3-coder-plus"), "qwen")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "glm-4.6"), "glm")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "grok-4"), "grok")
        XCTAssertEqual(RequestLog.inferProvider(fromModel: "deepseek-chat"), "deepseek")
    }

    func testInferProviderReturnsNilForUnknownOrEmptyModel() {
        XCTAssertNil(RequestLog.inferProvider(fromModel: "totally-unknown-model"))
        XCTAssertNil(RequestLog.inferProvider(fromModel: ""))
        XCTAssertNil(RequestLog.inferProvider(fromModel: nil))
    }

    // MARK: - Effective Provider

    func testEffectiveProviderPrefersResolvedProvider() {
        let log = makeLog(provider: "claude", model: "quotio-auto", resolvedModel: "kiro-claude-opus-4-5", resolvedProvider: "kiro")
        XCTAssertEqual(log.effectiveProvider, "kiro")
    }

    func testEffectiveProviderFallsBackToDetectedProvider() {
        let log = makeLog(provider: "gemini", model: "gemini-2.5-pro")
        XCTAssertEqual(log.effectiveProvider, "gemini")
    }

    func testEffectiveProviderInfersFromModelWhenProviderMissing() {
        let log = makeLog(provider: nil, model: "qwen3-coder-plus")
        XCTAssertEqual(log.effectiveProvider, "qwen")
    }

    func testEffectiveProviderInfersFromResolvedModelFirst() {
        let log = makeLog(provider: nil, model: "unknown-virtual", resolvedModel: "gemini-2.5-pro")
        XCTAssertEqual(log.effectiveProvider, "gemini")
    }

    func testEffectiveProviderIsNilWhenNothingCanBeDerived() {
        let log = makeLog(provider: nil, model: nil)
        XCTAssertNil(log.effectiveProvider)
    }

    // MARK: - Already-Persisted Rows

    /// Rows written before this change stored the protocol label. They must re-rank on read.
    func testPersistedProtocolLabelIsOverriddenByModelFamily() {
        let legacy = makeLog(provider: "openai", model: "qwen3-coder-plus", endpoint: "/v1/chat/completions")
        XCTAssertEqual(legacy.effectiveProvider, "qwen")
        XCTAssertEqual(RequestLog.displayName(forProvider: legacy.effectiveProvider ?? ""), "Qwen")
    }

    func testPersistedProtocolLabelSurvivesForGenuineOpenAIRows() {
        let legacy = makeLog(provider: "openai", model: "gpt-5.2", endpoint: "/v1/chat/completions")
        XCTAssertEqual(legacy.effectiveProvider, "openai")
    }

    func testPersistedAggregatorLabelIsNotOverriddenByModelFamily() {
        // Old path detection stored the bare "copilot" label; it still outranks the model name
        // and canonicalises onto the same id as the AIProvider raw value.
        let legacy = makeLog(provider: "copilot", model: "claude-3.5-sonnet", endpoint: "/copilot/v1/chat/completions")
        XCTAssertEqual(legacy.effectiveProvider, AIProvider.copilot.rawValue)
        XCTAssertEqual(RequestLog.displayName(forProvider: legacy.effectiveProvider ?? ""), "Copilot")
    }

    func testPersistedRowDecodedFromDiskReRanksProvider() throws {
        let stored = makeLog(provider: "openai", model: "glm-4.6", endpoint: "/v1/chat/completions")
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(RequestLog.self, from: data)

        XCTAssertEqual(decoded.provider, "openai", "raw stored value is untouched")
        XCTAssertEqual(decoded.effectiveProvider, "glm", "display value re-ranks on read")
    }

    // MARK: - Badge, Filter, Search, Stats

    /// End-to-end for the reviewer's exact case: `/v1/chat/completions` + `qwen3-coder-plus`.
    func testQwenOverOpenAIEndpointReachesBadgeFilterSearchAndStats() {
        let metadata = deriveProvider(path: "/v1/chat/completions", model: "qwen3-coder-plus")
        let log = makeLog(provider: metadata, model: "qwen3-coder-plus", endpoint: "/v1/chat/completions")

        // Badge
        XCTAssertEqual(log.effectiveProvider, "qwen")
        XCTAssertEqual(RequestLog.displayName(forProvider: log.effectiveProvider ?? ""), "Qwen")

        // Filter (mirrors LogsScreen.filteredRequests)
        XCTAssertTrue([log].filter { $0.effectiveProvider == "qwen" }.count == 1)
        XCTAssertTrue([log].filter { $0.effectiveProvider == "openai" }.isEmpty)

        // Search (mirrors LogsScreen.filteredRequests)
        XCTAssertTrue(matchesSearch(log, "qwen"))
        XCTAssertFalse(matchesSearch(log, "openai"))

        // Stats
        var store = RequestHistoryStore.empty
        store.addEntry(log)
        let stats = store.calculateStats()
        XCTAssertEqual(stats.byProvider["qwen"]?.requestCount, 1)
        XCTAssertNil(stats.byProvider["openai"])
    }

    func testStatsAggregateByEffectiveProvider() {
        var store = RequestHistoryStore.empty
        // provider is nil but derivable from model name
        store.addEntry(makeLog(provider: nil, model: "glm-4.6"))
        store.addEntry(makeLog(provider: "claude", model: "claude-sonnet-4-5"))
        // legacy protocol-labelled row for a non-OpenAI family
        store.addEntry(makeLog(provider: "openai", model: "deepseek-chat", endpoint: "/v1/chat/completions"))

        let stats = store.calculateStats()
        XCTAssertEqual(stats.byProvider["glm"]?.requestCount, 1)
        XCTAssertEqual(stats.byProvider["claude"]?.requestCount, 1)
        XCTAssertEqual(stats.byProvider["deepseek"]?.requestCount, 1)
        XCTAssertNil(stats.byProvider["openai"])
    }

    // MARK: - Helpers

    private func deriveProvider(path: String, model: String?) -> String? {
        RequestLog.deriveProvider(path: path, model: model)
    }

    /// Mirrors the search predicate in `LogsScreen.filteredRequests`.
    private func matchesSearch(_ log: RequestLog, _ text: String) -> Bool {
        (log.effectiveProvider?.localizedCaseInsensitiveContains(text) ?? false) ||
        (log.model?.localizedCaseInsensitiveContains(text) ?? false) ||
        log.endpoint.localizedCaseInsensitiveContains(text)
    }

    private func makeLog(
        provider: String?,
        model: String?,
        resolvedModel: String? = nil,
        resolvedProvider: String? = nil,
        endpoint: String = "/v1/messages"
    ) -> RequestLog {
        RequestLog(
            method: "POST",
            endpoint: endpoint,
            provider: provider,
            model: model,
            resolvedModel: resolvedModel,
            resolvedProvider: resolvedProvider,
            durationMs: 100,
            statusCode: 200
        )
    }
}
