import XCTest
@testable import Quotio

final class OpenCodeConfigTests: XCTestCase {

    private let quotioProvider: [String: Any] = [
        "models": ["claude-sonnet-4-5": ["name": "Claude Sonnet 4 5"]],
        "name": "Quotio",
        "npm": "@ai-sdk/anthropic",
        "options": [
            "apiKey": "quotio-local-test",
            "baseURL": "http://127.0.0.1:8317/v1",
            "litellmProxy": true
        ]
    ]

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - mergedOpenCodeJSON

    func testMergePreservesUserFieldsAndSetsQuotioProvider() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "$schema": "https://opencode.ai/config.json",
            "plugin": [
                "opencode-antigravity-auth@1.2.8",
                "opencode-openai-codex-auth"
            ],
            "theme": "dark",
            "provider": [
                "myrouter": [
                    "npm": "@ai-sdk/openai-compatible",
                    "options": ["baseURL": "https://example.com/v1"]
                ]
            ]
        ])

        let merged = try AgentConfigurationService.mergedOpenCodeJSON(
            existing: existing,
            quotioProvider: quotioProvider
        )
        let object = try jsonObject(merged)

        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertEqual(object["plugin"] as? [String], [
            "opencode-antigravity-auth@1.2.8",
            "opencode-openai-codex-auth"
        ])

        let providers = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertNotNil(providers["myrouter"], "Existing custom provider must survive the merge")
        let quotio = try XCTUnwrap(providers["quotio"] as? [String: Any])
        let options = try XCTUnwrap(quotio["options"] as? [String: Any])
        XCTAssertEqual(options["apiKey"] as? String, "quotio-local-test")
    }

    func testMergeParsesJSONCWithCommentsAndTrailingCommas() throws {
        let jsonc = """
        {
          // user plugins
          "plugin": [
            "opencode-antigravity-auth@1.2.8",
            // "oh-my-opencode",
            "opencode-openai-codex-auth",
          ],
          /* block comment */
          "theme": "dark",
        }
        """

        let merged = try AgentConfigurationService.mergedOpenCodeJSON(
            existing: Data(jsonc.utf8),
            quotioProvider: quotioProvider
        )
        let object = try jsonObject(merged)

        XCTAssertEqual(object["plugin"] as? [String], [
            "opencode-antigravity-auth@1.2.8",
            "opencode-openai-codex-auth"
        ])
        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertNotNil((object["provider"] as? [String: Any])?["quotio"])
    }

    func testMergeWithoutExistingFileProducesSchemaAndProviderOnly() throws {
        let merged = try AgentConfigurationService.mergedOpenCodeJSON(
            existing: nil,
            quotioProvider: quotioProvider
        )
        let object = try jsonObject(merged)

        XCTAssertEqual(object.count, 2)
        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertNotNil((object["provider"] as? [String: Any])?["quotio"])
    }

    func testMergeThrowsOnUnparseableExistingContent() {
        let corrupt = Data("{ definitely not json".utf8)
        XCTAssertThrowsError(
            try AgentConfigurationService.mergedOpenCodeJSON(
                existing: corrupt,
                quotioProvider: quotioProvider
            )
        )
    }

    func testMergeOverwritesStaleQuotioEntryOnly() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "plugin": ["some-plugin"],
            "provider": [
                "quotio": ["options": ["apiKey": "stale-key"]],
                "other": ["npm": "@ai-sdk/openai-compatible"]
            ]
        ])

        let merged = try AgentConfigurationService.mergedOpenCodeJSON(
            existing: existing,
            quotioProvider: quotioProvider
        )
        let object = try jsonObject(merged)

        XCTAssertEqual(object["plugin"] as? [String], ["some-plugin"])
        let providers = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertNotNil(providers["other"])
        let quotio = try XCTUnwrap(providers["quotio"] as? [String: Any])
        let options = try XCTUnwrap(quotio["options"] as? [String: Any])
        XCTAssertEqual(options["apiKey"] as? String, "quotio-local-test")
    }

    // MARK: - openCodeJSONRemovingQuotioProvider

    func testRemoveDeletesOnlyQuotioProvider() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "plugin": ["opencode-antigravity-auth@1.2.8"],
            "theme": "dark",
            "provider": [
                "quotio": ["name": "Quotio"],
                "myrouter": ["npm": "@ai-sdk/openai-compatible"]
            ]
        ])

        let updated = try XCTUnwrap(
            AgentConfigurationService.openCodeJSONRemovingQuotioProvider(existing: existing)
        )
        let object = try jsonObject(updated)

        XCTAssertEqual(object["plugin"] as? [String], ["opencode-antigravity-auth@1.2.8"])
        XCTAssertEqual(object["theme"] as? String, "dark")
        let providers = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertNil(providers["quotio"])
        XCTAssertNotNil(providers["myrouter"])
    }

    func testRemoveDropsEmptyProviderObject() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "theme": "dark",
            "provider": ["quotio": ["name": "Quotio"]]
        ])

        let updated = try XCTUnwrap(
            AgentConfigurationService.openCodeJSONRemovingQuotioProvider(existing: existing)
        )
        let object = try jsonObject(updated)

        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertNil(object["provider"])
    }

    func testRemoveReturnsNilWhenNothingToRemove() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "plugin": ["some-plugin"],
            "provider": ["myrouter": ["npm": "@ai-sdk/openai-compatible"]]
        ])

        XCTAssertNil(
            try AgentConfigurationService.openCodeJSONRemovingQuotioProvider(existing: existing)
        )
    }

    func testRemoveParsesJSONCInput() throws {
        let jsonc = """
        {
          "plugin": ["some-plugin"], // keep me
          "provider": {
            "quotio": { "name": "Quotio" },
          },
        }
        """

        let updated = try XCTUnwrap(
            AgentConfigurationService.openCodeJSONRemovingQuotioProvider(existing: Data(jsonc.utf8))
        )
        let object = try jsonObject(updated)

        XCTAssertEqual(object["plugin"] as? [String], ["some-plugin"])
        XCTAssertNil(object["provider"])
    }

    func testRemoveThrowsOnUnparseableContent() {
        let corrupt = Data("not json at all".utf8)
        XCTAssertThrowsError(
            try AgentConfigurationService.openCodeJSONRemovingQuotioProvider(existing: corrupt)
        )
    }

    // MARK: - strippingJSONCSyntax

    func testStrippingLeavesStringContentsUntouched() throws {
        let jsonc = """
        {
          "$schema": "https://opencode.ai/config.json", // schema URL has //
          "note": "a /* not a comment */ b",
          "escaped": "quote \\" then // still in string",
        }
        """

        let stripped = AgentConfigurationService.strippingJSONCSyntax(from: jsonc)
        let object = try jsonObject(Data(stripped.utf8))

        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(object["note"] as? String, "a /* not a comment */ b")
        XCTAssertEqual(object["escaped"] as? String, "quote \" then // still in string")
    }

    func testStrippingHandlesNestedTrailingCommas() throws {
        let jsonc = """
        {
          "a": [1, 2, 3,],
          "b": { "c": [ { "d": 1, }, ], },
        }
        """

        let stripped = AgentConfigurationService.strippingJSONCSyntax(from: jsonc)
        let object = try jsonObject(Data(stripped.utf8))

        XCTAssertEqual(object["a"] as? [Int], [1, 2, 3])
        let b = try XCTUnwrap(object["b"] as? [String: Any])
        let c = try XCTUnwrap(b["c"] as? [[String: Any]])
        XCTAssertEqual(c.first?["d"] as? Int, 1)
    }
}
