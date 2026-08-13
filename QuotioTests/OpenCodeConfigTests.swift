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

    private func merged(_ source: String) throws -> String {
        let data = try OpenCodeConfigEditor.merging(
            existing: Data(source.utf8),
            providers: ["quotio": quotioProvider]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// The reporter's config from #176: comments, a commented-out plugin line,
    /// unrelated top-level keys, nested objects and arrays, another provider.
    private let reporterConfig = """
    {
      "$schema": "https://opencode.ai/config.json",
      // plugins are load-bearing, do not touch
      "plugin": [
        "opencode-antigravity-auth@1.2.8",
        // "oh-my-opencode",
        "opencode-openai-codex-auth"
      ],
      "theme": "opencode",
      "keybinds": { "leader": "ctrl+x", "app_exit": "ctrl+c" },
      "mcp": {
        "local-tools": {
          "type": "local",
          "command": ["bun", "x", "my-mcp-server"],
          "enabled": true
        }
      },
      "provider": {
        /* my own router */
        "myrouter": {
          "npm": "@ai-sdk/openai-compatible",
          "options": { "baseURL": "https://example.com/v1" }
        }
      }
    }
    """

    // MARK: - Round-trip fidelity (#176)

    func testMergeThenRemoveRestoresTheOriginalByteForByte() throws {
        let mergedText = try merged(reporterConfig)
        let restored = try XCTUnwrap(
            OpenCodeConfigEditor.removingProviders(existing: Data(mergedText.utf8), keys: ["quotio"])
        )
        XCTAssertEqual(String(decoding: restored, as: UTF8.self), reporterConfig)
    }

    func testMergeKeepsEverythingOutsideProviderQuotioVerbatim() throws {
        let mergedText = try merged(reporterConfig)

        // Everything before the `provider` object is untouched, including the
        // commented-out plugin line the reporter lost.
        let providerMarker = try XCTUnwrap(reporterConfig.range(of: "  \"provider\": {"))
        XCTAssertTrue(
            mergedText.hasPrefix(String(reporterConfig[..<providerMarker.lowerBound])),
            "Content above provider must survive verbatim"
        )
        XCTAssertTrue(mergedText.contains("// \"oh-my-opencode\","))
        XCTAssertTrue(mergedText.contains("// plugins are load-bearing, do not touch"))
        XCTAssertTrue(mergedText.contains("/* my own router */"))
        XCTAssertTrue(mergedText.contains("\"command\": [\"bun\", \"x\", \"my-mcp-server\"],"))
        XCTAssertTrue(mergedText.contains("\"keybinds\": { \"leader\": \"ctrl+x\", \"app_exit\": \"ctrl+c\" },"))
        XCTAssertTrue(mergedText.hasSuffix("}"))

        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: mergedText).utf8
        ))
        let providers = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertNotNil(providers["myrouter"])
        let quotio = try XCTUnwrap(providers["quotio"] as? [String: Any])
        let options = try XCTUnwrap(quotio["options"] as? [String: Any])
        XCTAssertEqual(options["apiKey"] as? String, "quotio-local-test")
    }

    func testReconfiguringTwiceIsIdempotent() throws {
        let once = try merged(reporterConfig)
        XCTAssertEqual(try merged(once), once)
    }

    func testMergeDoesNotAddSchemaToAnExistingFileThatOmitsIt() throws {
        let source = """
        {
          "theme": "system"
        }
        """
        let mergedText = try merged(source)
        XCTAssertFalse(mergedText.contains("$schema"))
        XCTAssertTrue(mergedText.contains("\"theme\": \"system\","))
    }

    func testMergeReplacesOnlyTheQuotioValueOnReconfigure() throws {
        let source = """
        {
          "provider": {
            // Quotio-managed, edited by the app
            "quotio": { "options": { "apiKey": "stale" } },
            "other": { "npm": "@ai-sdk/openai-compatible" }
          }
        }
        """
        let mergedText = try merged(source)
        XCTAssertTrue(mergedText.contains("// Quotio-managed, edited by the app"))
        XCTAssertTrue(mergedText.contains("\"other\": { \"npm\": \"@ai-sdk/openai-compatible\" }"))
        XCTAssertFalse(mergedText.contains("stale"))
        XCTAssertTrue(mergedText.contains("quotio-local-test"))
    }

    func testMergeInsertsProviderWhenAbsent() throws {
        let source = """
        {
          "theme": "system", // trailing comment on the last member
          "plugin": ["a"]
        }
        """
        let mergedText = try merged(source)
        XCTAssertTrue(mergedText.contains("// trailing comment on the last member"))
        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: mergedText).utf8
        ))
        XCTAssertEqual(object["plugin"] as? [String], ["a"])
        XCTAssertNotNil((object["provider"] as? [String: Any])?["quotio"])
    }

    func testMergeIntoEmptyProviderObject() throws {
        let source = """
        {
          "provider": {}
        }
        """
        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: try merged(source)).utf8
        ))
        XCTAssertNotNil((object["provider"] as? [String: Any])?["quotio"])
    }

    func testMergeKeepsExistingTrailingCommaInsteadOfDoublingIt() throws {
        let source = """
        {
          "provider": {
            "other": { "npm": "x" },
          },
        }
        """
        let mergedText = try merged(source)
        XCTAssertFalse(mergedText.contains(",,"))
        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: mergedText).utf8
        ))
        let providers = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertNotNil(providers["other"])
        XCTAssertNotNil(providers["quotio"])
    }

    func testMergePreservesCRLFAndByteOrderMark() throws {
        let source = "\u{FEFF}{\r\n  // keep\r\n  \"theme\": \"system\"\r\n}"
        let mergedText = try merged(source)
        XCTAssertTrue(mergedText.hasPrefix("\u{FEFF}{\r\n  // keep\r\n"))
        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: mergedText).utf8
        ))
        XCTAssertEqual(object["theme"] as? String, "system")
        XCTAssertNotNil((object["provider"] as? [String: Any])?["quotio"])
    }

    func testMergeWithoutExistingFileProducesSchemaAndProviderOnly() throws {
        let object = try jsonObject(
            try OpenCodeConfigEditor.merging(existing: nil, providers: ["quotio": quotioProvider])
        )
        XCTAssertEqual(object.count, 2)
        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertNotNil((object["provider"] as? [String: Any])?["quotio"])
    }

    func testMergeTreatsWhitespaceOnlyFileAsNew() throws {
        let object = try jsonObject(
            try OpenCodeConfigEditor.merging(existing: Data("\n\n  ".utf8), providers: ["quotio": quotioProvider])
        )
        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
    }

    // MARK: - Refusals: the parser must never manufacture validity

    private func assertMergeRefuses(
        _ source: String,
        _ expected: OpenCodeConfigError? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try OpenCodeConfigEditor.merging(
                existing: Data(source.utf8),
                providers: ["quotio": quotioProvider]
            ),
            file: file,
            line: line
        ) { error in
            if let expected {
                XCTAssertEqual(error as? OpenCodeConfigError, expected, file: file, line: line)
            }
        }
    }

    /// Reviewer's case 1: stripping a closed block comment must not fuse the
    /// tokens on either side into a new, valid token.
    func testBlockCommentRemovalPreservesTokenBoundary() throws {
        let stripped = try OpenCodeConfigEditor.strippingJSONCSyntax(from: "[{\"value\": 1/* x */2}]")
        XCTAssertEqual(stripped, "[{\"value\": 1 2}]")
        XCTAssertThrowsError(try OpenCodeConfigEditor.parseObject(Data("{\"value\": 1/* x */2}".utf8)))
        assertMergeRefuses("{\"value\": 1/* x */2}")
    }

    /// Reviewer's case 2: a valid document followed by an unterminated block
    /// comment must not be accepted by silently discarding the rest.
    func testUnterminatedBlockCommentIsRejected() {
        let source = """
        {
          "theme": "system"
        }
        /* oops, never closed
        """
        XCTAssertThrowsError(try OpenCodeConfigEditor.parseObject(Data(source.utf8))) { error in
            XCTAssertEqual(error as? OpenCodeConfigError, .unterminatedBlockComment)
        }
        assertMergeRefuses(source, .unterminatedBlockComment)
        assertMergeRefuses("{ /* never closed \"theme\": \"system\" }", .unterminatedBlockComment)
    }

    func testUnterminatedStringIsRejected() {
        assertMergeRefuses("{\n  \"theme\": \"system\n}", .unterminatedString)
        assertMergeRefuses("{\n  \"theme\": \"system", .unterminatedString)
    }

    /// JSONC has no nested block comments: the first `*/` closes, leaving stray
    /// `*/` that must be reported instead of silently dropped.
    func testNestedBlockCommentIsRejected() {
        assertMergeRefuses("{ /* outer /* inner */ */ \"theme\": \"system\" }")
    }

    func testTrailingContentAfterRootIsRejected() {
        assertMergeRefuses("{\"theme\": \"system\"} {\"theme\": \"other\"}")
    }

    func testRootThatIsNotAnObjectIsRejected() {
        assertMergeRefuses("[{\"theme\": \"system\"}]", .rootNotObject)
    }

    func testDuplicateProviderKeyIsRejected() {
        assertMergeRefuses(
            "{\"provider\": {\"a\": {}}, \"provider\": {\"b\": {}}}",
            .duplicateKey("provider")
        )
    }

    func testNonObjectProviderIsRejected() {
        assertMergeRefuses("{\"provider\": \"nope\"}", .providerNotObject)
        assertMergeRefuses("{\"provider\": null}", .providerNotObject)
    }

    func testNonUTF8InputIsRejected() {
        XCTAssertThrowsError(
            try OpenCodeConfigEditor.merging(
                existing: Data([0x7B, 0xFF, 0xFE, 0x7D]),
                providers: ["quotio": quotioProvider]
            )
        ) { error in
            XCTAssertEqual(error as? OpenCodeConfigError, .notUTF8)
        }
    }

    func testMissingCommaBetweenMembersIsRejected() {
        assertMergeRefuses("{\n  \"a\": 1\n  \"b\": 2\n}")
    }

    // MARK: - Comment/comma markers that live inside string literals

    func testCommentMarkersInsideStringsAreNotComments() throws {
        let source = """
        {
          "$schema": "https://opencode.ai/config.json",
          "note": "a /* not a comment */ b",
          "escaped": "quote \\" then // still in string",
          "commaish": "value, }"
        }
        """
        let mergedText = try merged(source)
        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: mergedText).utf8
        ))
        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(object["note"] as? String, "a /* not a comment */ b")
        XCTAssertEqual(object["escaped"] as? String, "quote \" then // still in string")
        XCTAssertEqual(object["commaish"] as? String, "value, }")
    }

    func testStrippingHandlesNestedTrailingCommas() throws {
        let jsonc = """
        {
          "a": [1, 2, 3,],
          "b": { "c": [ { "d": 1, }, ], },
        }
        """
        let object = try jsonObject(Data(
            OpenCodeConfigEditor.strippingJSONCSyntax(from: jsonc).utf8
        ))
        XCTAssertEqual(object["a"] as? [Int], [1, 2, 3])
        let b = try XCTUnwrap(object["b"] as? [String: Any])
        let c = try XCTUnwrap(b["c"] as? [[String: Any]])
        XCTAssertEqual(c.first?["d"] as? Int, 1)
    }

    // MARK: - Removal (default-config path)

    func testRemoveDeletesOnlyQuotioAndKeepsComments() throws {
        let source = """
        {
          // top comment
          "plugin": ["opencode-antigravity-auth@1.2.8"],
          "provider": {
            "quotio": { "name": "Quotio" },
            /* mine */
            "myrouter": { "npm": "@ai-sdk/openai-compatible" }
          }
        }
        """
        let updated = try XCTUnwrap(
            OpenCodeConfigEditor.removingProviders(existing: Data(source.utf8), keys: ["quotio"])
        )
        let text = String(decoding: updated, as: UTF8.self)
        XCTAssertEqual(text, """
        {
          // top comment
          "plugin": ["opencode-antigravity-auth@1.2.8"],
          "provider": {
            /* mine */
            "myrouter": { "npm": "@ai-sdk/openai-compatible" }
          }
        }
        """)
    }

    func testRemoveDropsTheWholeProviderMemberWhenQuotioWasItsOnlyEntry() throws {
        let source = """
        {
          "theme": "dark",
          "provider": {
            "quotio": { "name": "Quotio" }
          }
        }
        """
        let updated = try XCTUnwrap(
            OpenCodeConfigEditor.removingProviders(existing: Data(source.utf8), keys: ["quotio"])
        )
        XCTAssertEqual(String(decoding: updated, as: UTF8.self), """
        {
          "theme": "dark"
        }
        """)
    }

    func testRemoveReturnsNilWhenNothingToRemove() throws {
        let source = """
        {
          "provider": { "myrouter": { "npm": "@ai-sdk/openai-compatible" } }
        }
        """
        XCTAssertNil(
            try OpenCodeConfigEditor.removingProviders(existing: Data(source.utf8), keys: ["quotio"])
        )
        XCTAssertNil(
            try OpenCodeConfigEditor.removingProviders(existing: Data("{}".utf8), keys: ["quotio"])
        )
    }

    func testRemoveRefusesUnparseableContent() {
        XCTAssertThrowsError(
            try OpenCodeConfigEditor.removingProviders(
                existing: Data("not json at all".utf8),
                keys: ["quotio"]
            )
        )
    }
}
