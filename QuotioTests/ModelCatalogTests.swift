import XCTest
@testable import Quotio

final class ModelCatalogTests: XCTestCase {

    private func data(_ json: String) throws -> Data {
        try XCTUnwrap(json.data(using: .utf8))
    }

    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let laterFetchedAt = Date(timeIntervalSince1970: 1_700_003_600)

    private func entries(_ ids: String...) -> [ModelCatalogEntry] {
        ids.map { ModelCatalogEntry(id: $0, owner: nil) }
    }

    // MARK: - Parsing mirrors the response exactly

    func testParseReadsIdAndOwnedByFromModelsResponse() throws {
        let payload = try data("""
        {
          "object": "list",
          "data": [
            { "id": "gpt-5.2", "object": "model", "owned_by": "openai" },
            { "id": "gemini-3-pro-preview", "object": "model", "owned_by": "google" }
          ]
        }
        """)

        let parsed = try ModelCatalog.parse(payload)

        XCTAssertEqual(parsed.map(\.id), ["gpt-5.2", "gemini-3-pro-preview"])
        XCTAssertEqual(parsed.map(\.owner), ["openai", "google"])
    }

    func testParseKeepsMissingOwnedByAsNilRatherThanInventingOne() throws {
        let payload = try data(#"{ "data": [ { "id": "custom-model" } ] }"#)

        let parsed = try ModelCatalog.parse(payload)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertNil(parsed[0].owner)
        XCTAssertNil(parsed[0].displayOwner)
    }

    func testDisplayOwnerTreatsBlankOwnedByAsAbsent() throws {
        let payload = try data("""
        { "data": [
            { "id": "blank", "owned_by": "" },
            { "id": "whitespace", "owned_by": "   " },
            { "id": "padded", "owned_by": "  google  " }
        ] }
        """)

        let parsed = try ModelCatalog.parse(payload)

        XCTAssertNil(parsed[0].displayOwner)
        XCTAssertNil(parsed[1].displayOwner)
        XCTAssertEqual(parsed[2].displayOwner, "google")
    }

    func testParseReturnsEmptyListForEmptyResponse() throws {
        XCTAssertTrue(try ModelCatalog.parse(try data(#"{ "data": [] }"#)).isEmpty)
    }

    func testParseThrowsOnMalformedResponse() throws {
        XCTAssertThrowsError(try ModelCatalog.parse(try data(#"{ "models": [ { "id": "gpt-5.2" } ] }"#)))
    }

    // MARK: - Display ordering / deduplication (no routing meaning attached)

    func testDisplayEntriesSortsByIdCaseInsensitively() {
        let sorted = ModelCatalog.displayEntries(entries("gpt-5.2", "Gemini-3-pro", "gpt-5.1"))

        XCTAssertEqual(sorted.map(\.id), ["Gemini-3-pro", "gpt-5.1", "gpt-5.2"])
    }

    func testDisplayEntriesCollapsesRepeatedIdsKeepingFirstOccurrence() {
        // CLIProxyAPI deduplicates /v1/models by ID, so a repeated ID is a single
        // model whose owner metadata may have been replaced - not two routes.
        let input = [
            ModelCatalogEntry(id: "claude-sonnet-4-5", owner: "anthropic"),
            ModelCatalogEntry(id: "claude-sonnet-4-5", owner: "github-copilot")
        ]

        let displayed = ModelCatalog.displayEntries(input)

        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed[0].owner, "anthropic")
    }

    func testDisplayEntriesReturnsEmptyForNoEntries() {
        XCTAssertTrue(ModelCatalog.displayEntries([]).isEmpty)
    }

    func testParseThenDisplayProducesFlatSortedListEndToEnd() throws {
        let payload = try data("""
        {
          "data": [
            { "id": "gpt-5.2", "owned_by": "openai" },
            { "id": "gemini-3-flash-preview", "owned_by": "google" },
            { "id": "gpt-5.1-codex", "owned_by": "openai" },
            { "id": "unowned-model" }
          ]
        }
        """)

        let displayed = ModelCatalog.displayEntries(try ModelCatalog.parse(payload))

        XCTAssertEqual(
            displayed.map(\.id),
            ["gemini-3-flash-preview", "gpt-5.1-codex", "gpt-5.2", "unowned-model"]
        )
        XCTAssertEqual(displayed.map(\.displayOwner), ["google", "openai", "openai", nil])
    }

    // MARK: - Live vs stale vs built-in state

    func testInitialStateHasNotFetchedAnything() {
        let state = ModelCatalogState()

        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertEqual(state.freshness, .never)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.lastFetchFailed)
        XCTAssertFalse(state.hasCompletedFetch)
        XCTAssertFalse(state.isEmptyLiveResult)
    }

    func testSuccessfulFetchIsMarkedLiveWithItsTimestamp() {
        var state = ModelCatalogState()
        state.beginLoading()
        XCTAssertTrue(state.isLoading)

        state.apply(entries: entries("gpt-5.2", "gemini-3-flash-preview"), fetchedAt: fetchedAt)

        XCTAssertEqual(state.entries.map(\.id), ["gemini-3-flash-preview", "gpt-5.2"])
        XCTAssertEqual(state.freshness, .live(fetchedAt: fetchedAt))
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.lastFetchFailed)
        XCTAssertTrue(state.hasCompletedFetch)
    }

    func testSuccessfulEmptyResponseStaysEmptyInsteadOfShowingBuiltInModels() {
        var state = ModelCatalogState()
        state.beginLoading()

        state.apply(entries: [], fetchedAt: fetchedAt)

        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertTrue(state.isEmptyLiveResult, "The empty state must be reachable, not masked by defaults")
        XCTAssertEqual(state.freshness, .live(fetchedAt: fetchedAt))
        XCTAssertTrue(state.hasCompletedFetch)
        XCTAssertFalse(state.lastFetchFailed)

        let builtInIds = Set(AvailableModel.allModels.map(\.id))
        XCTAssertTrue(state.entries.allSatisfy { !builtInIds.contains($0.id) })
    }

    func testFailedFirstFetchReportsFailureWithNothingToShow() {
        var state = ModelCatalogState()
        state.beginLoading()

        state.applyFailure()

        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertEqual(state.freshness, .never, "A failure must not be dressed up as a fetched list")
        XCTAssertTrue(state.lastFetchFailed)
        XCTAssertTrue(state.hasCompletedFetch)
        XCTAssertFalse(state.isEmptyLiveResult)
        XCTAssertFalse(state.isLoading)
    }

    func testFailedRefreshDemotesPreviousResultToStaleAndKeepsItsOriginalTimestamp() {
        var state = ModelCatalogState()
        state.apply(entries: entries("gpt-5.2"), fetchedAt: fetchedAt)

        state.beginLoading()
        state.applyFailure()

        XCTAssertEqual(state.entries.map(\.id), ["gpt-5.2"], "The last known list stays visible")
        XCTAssertEqual(state.freshness, .stale(fetchedAt: fetchedAt), "But it is no longer presented as live")
        XCTAssertTrue(state.lastFetchFailed)
        XCTAssertFalse(state.isEmptyLiveResult)
    }

    func testRepeatedFailuresKeepTheOriginalSuccessTimestamp() {
        var state = ModelCatalogState()
        state.apply(entries: entries("gpt-5.2"), fetchedAt: fetchedAt)
        state.applyFailure()
        state.applyFailure()

        XCTAssertEqual(state.freshness, .stale(fetchedAt: fetchedAt))
    }

    func testSuccessfulRefreshAfterFailurePromotesBackToLive() {
        var state = ModelCatalogState()
        state.apply(entries: entries("gpt-5.2"), fetchedAt: fetchedAt)
        state.applyFailure()

        state.apply(entries: entries("gpt-5.3-codex"), fetchedAt: laterFetchedAt)

        XCTAssertEqual(state.entries.map(\.id), ["gpt-5.3-codex"])
        XCTAssertEqual(state.freshness, .live(fetchedAt: laterFetchedAt))
        XCTAssertFalse(state.lastFetchFailed)
    }

    func testSuccessfulRefreshReplacesRatherThanMergesPreviousEntries() {
        var state = ModelCatalogState()
        state.apply(entries: entries("gpt-5.1", "gpt-5.2"), fetchedAt: fetchedAt)

        state.apply(entries: entries("gpt-5.2"), fetchedAt: laterFetchedAt)

        XCTAssertEqual(state.entries.map(\.id), ["gpt-5.2"], "Removed models must not linger")
    }

    func testResetClearsEverythingSoAStoppedProxyShowsNoStaleList() {
        var state = ModelCatalogState()
        state.apply(entries: entries("gpt-5.2"), fetchedAt: fetchedAt)

        state.reset()

        XCTAssertEqual(state, ModelCatalogState())
    }

    // MARK: - Existing agent-setup consumers are unaffected

    func testAgentSetupMappingPreservesHistoricalOpenAIProviderDefault() {
        // AgentConfigurationService.fetchAvailableModels - and through it the agent
        // config sheet, warmup sheet and fallback screen - depends on `owned_by`
        // defaulting to "openai" and on the "github-copilot" value being preserved
        // verbatim for its Copilot availability filter.
        let mapped = ModelCatalog.agentSetupModels(from: [
            ModelCatalogEntry(id: "gpt-5.2", owner: "openai"),
            ModelCatalogEntry(id: "custom-model", owner: nil),
            ModelCatalogEntry(id: "claude-sonnet-4-5", owner: "github-copilot")
        ])

        XCTAssertEqual(mapped.map(\.provider), ["openai", "openai", "github-copilot"])
        XCTAssertEqual(mapped.map(\.id), ["gpt-5.2", "custom-model", "claude-sonnet-4-5"])
        XCTAssertEqual(mapped.map(\.name), mapped.map(\.id))
        XCTAssertTrue(mapped.allSatisfy { !$0.isDefault })
    }

    func testAgentSetupMappingPreservesResponseOrderAndDuplicates() {
        // The picker path must keep seeing the unmodified response; only the
        // read-only catalog view sorts and deduplicates for display.
        let mapped = ModelCatalog.agentSetupModels(from: [
            ModelCatalogEntry(id: "gpt-5.2", owner: "openai"),
            ModelCatalogEntry(id: "gemini-3-flash-preview", owner: "google"),
            ModelCatalogEntry(id: "gpt-5.2", owner: "openai")
        ])

        XCTAssertEqual(mapped.map(\.id), ["gpt-5.2", "gemini-3-flash-preview", "gpt-5.2"])
    }

    func testBuiltInModelListStillAvailableForTheAgentSetupPickerFallback() {
        // loadModels(forceRefresh:) intentionally keeps this fallback for pickers;
        // the catalog view simply must not route through it.
        XCTAssertFalse(AvailableModel.allModels.isEmpty)
    }

    @MainActor
    func testCatalogFetchWithoutAProxyThrowsInsteadOfFallingBackToDefaults() async {
        let viewModel = AgentSetupViewModel()

        do {
            _ = try await viewModel.fetchModelCatalog()
            XCTFail("Expected a thrown error when no proxy is configured")
        } catch {
            XCTAssertEqual(error as? ModelCatalogError, .proxyUnavailable)
        }

        XCTAssertTrue(
            viewModel.availableModels.isEmpty,
            "The catalog path must not populate the shared agent-setup model list"
        )
    }

    @MainActor
    func testLoadModelsWithoutAProxyStillReportsFailureWithoutTouchingModels() async {
        // Guards the unchanged behavior of the shared picker loader.
        let viewModel = AgentSetupViewModel()

        let loadedFromRemote = await viewModel.loadModels()

        XCTAssertFalse(loadedFromRemote)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }
}
