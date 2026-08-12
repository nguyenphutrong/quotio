import XCTest
@testable import Quotio

@MainActor
final class RequestLogProviderTests: XCTestCase {

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

    // MARK: - Stats Aggregation

    func testStatsAggregateByEffectiveProvider() {
        var store = RequestHistoryStore.empty
        // provider is nil but derivable from model name
        store.addEntry(makeLog(provider: nil, model: "glm-4.6"))
        store.addEntry(makeLog(provider: "claude", model: "claude-sonnet-4-5"))

        let stats = store.calculateStats()
        XCTAssertEqual(stats.byProvider["glm"]?.requestCount, 1)
        XCTAssertEqual(stats.byProvider["claude"]?.requestCount, 1)
    }

    // MARK: - Helpers

    private func makeLog(
        provider: String?,
        model: String?,
        resolvedModel: String? = nil,
        resolvedProvider: String? = nil
    ) -> RequestLog {
        RequestLog(
            method: "POST",
            endpoint: "/v1/messages",
            provider: provider,
            model: model,
            resolvedModel: resolvedModel,
            resolvedProvider: resolvedProvider,
            durationMs: 100,
            statusCode: 200
        )
    }
}
