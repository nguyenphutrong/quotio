import XCTest
@testable import Quotio

final class ModelCatalogTests: XCTestCase {

    private func data(_ json: String) throws -> Data {
        try XCTUnwrap(json.data(using: .utf8))
    }

    // MARK: - Parsing

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

        let models = try ModelCatalog.parse(payload)

        XCTAssertEqual(models.map(\.id), ["gpt-5.2", "gemini-3-pro-preview"])
        XCTAssertEqual(models.map(\.provider), ["openai", "google"])
        XCTAssertEqual(models.map(\.name), models.map(\.id))
        XCTAssertTrue(models.allSatisfy { !$0.isDefault })
    }

    func testParseDefaultsMissingOwnedByToOpenAI() throws {
        let payload = try data(#"{ "data": [ { "id": "custom-model" } ] }"#)

        let models = try ModelCatalog.parse(payload)

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].provider, "openai")
    }

    func testParseReturnsEmptyListForEmptyResponse() throws {
        let models = try ModelCatalog.parse(try data(#"{ "data": [] }"#))

        XCTAssertTrue(models.isEmpty)
    }

    func testParseThrowsOnMalformedResponse() throws {
        let payload = try data(#"{ "models": [ { "id": "gpt-5.2" } ] }"#)

        XCTAssertThrowsError(try ModelCatalog.parse(payload))
    }

    // MARK: - Grouping

    func testGroupByProviderGroupsAndSortsModels() {
        let models = [
            AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false),
            AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "google", isDefault: false),
            AvailableModel(id: "gpt-5.1", name: "gpt-5.1", provider: "openai", isDefault: false),
            AvailableModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", provider: "google", isDefault: false)
        ]

        let groups = ModelCatalog.groupByProvider(models)

        XCTAssertEqual(groups.map(\.provider), ["google", "openai"])
        XCTAssertEqual(groups[0].models.map(\.id), ["gemini-2.5-flash", "gemini-3-pro-preview"])
        XCTAssertEqual(groups[1].models.map(\.id), ["gpt-5.1", "gpt-5.2"])
        XCTAssertEqual(groups[0].id, "google")
    }

    func testGroupByProviderCollapsesDuplicateModelIdsWithinProvider() {
        let models = [
            AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false),
            AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false)
        ]

        let groups = ModelCatalog.groupByProvider(models)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].models.map(\.id), ["gpt-5.2"])
    }

    func testGroupByProviderKeepsSameModelIdOfferedByDifferentProviders() {
        let models = [
            AvailableModel(id: "claude-sonnet-4-5", name: "claude-sonnet-4-5", provider: "anthropic", isDefault: false),
            AvailableModel(id: "claude-sonnet-4-5", name: "claude-sonnet-4-5", provider: "github-copilot", isDefault: false)
        ]

        let groups = ModelCatalog.groupByProvider(models)

        XCTAssertEqual(groups.map(\.provider), ["anthropic", "github-copilot"])
        XCTAssertEqual(groups.flatMap { $0.models.map(\.id) }.count, 2)
    }

    func testGroupByProviderReturnsEmptyForNoModels() {
        XCTAssertTrue(ModelCatalog.groupByProvider([]).isEmpty)
    }

    func testParseThenGroupProducesProviderSectionsEndToEnd() throws {
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

        let groups = ModelCatalog.groupByProvider(try ModelCatalog.parse(payload))

        XCTAssertEqual(groups.map(\.provider), ["google", "openai"])
        XCTAssertEqual(groups[0].models.map(\.id), ["gemini-3-flash-preview"])
        XCTAssertEqual(groups[1].models.map(\.id), ["gpt-5.1-codex", "gpt-5.2", "unowned-model"])
    }
}
