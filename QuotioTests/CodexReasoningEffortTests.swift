import XCTest
@testable import Quotio

final class CodexReasoningEffortTests: XCTestCase {
    private let service = AgentConfigurationService()

    private let proxyURL = "http://127.0.0.1:8317/v1"

    // MARK: - Accepted Values
    //
    // Codex parses `model_reasoning_effort` as an OPEN set. `ReasoningEffort` in
    // codex-rs/protocol/src/openai_models.rs names none/minimal/low/medium/high/
    // xhigh/max/ultra and its `FromStr` maps every other non-empty string to
    // `ReasoningEffort::Custom`; only the empty string is rejected.

    func testNamedEffortsCoverEveryValueCodexNames() {
        XCTAssertEqual(
            CodexReasoningEffort.allCases.map(\.rawValue),
            ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
    }

    func testNamedValuesDecodeToNamedCasesNotCustom() {
        for effort in CodexReasoningEffort.allCases {
            let decoded = CodexReasoningEffort(rawValue: effort.rawValue)
            XCTAssertEqual(decoded, effort)
            if case .custom = decoded {
                XCTFail("\(effort.rawValue) must not decode as a custom value")
            }
        }
    }

    func testUnknownNonEmptyValueDecodesAsCustomAndRoundTrips() {
        let decoded = CodexReasoningEffort(rawValue: "turbo")
        XCTAssertEqual(decoded, .custom("turbo"))
        XCTAssertEqual(decoded?.rawValue, "turbo")
    }

    func testEmptyValueIsRejected() {
        // Codex errors with "reasoning_effort must not be empty".
        XCTAssertNil(CodexReasoningEffort(rawValue: ""))
    }

    func testCodableRoundTripsCustomValue() throws {
        let encoded = try JSONEncoder().encode(CodexReasoningEffort.custom("turbo"))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"turbo\"")

        let decoded = try JSONDecoder().decode(CodexReasoningEffort.self, from: encoded)
        XCTAssertEqual(decoded, .custom("turbo"))
    }

    // MARK: - Section-Aware Parsing

    func testTopLevelValueWinsOverProfileValues() async {
        let content = """
        model_provider = "cliproxyapi"
        model_reasoning_effort = "low"

        [profiles.work]
        model_reasoning_effort = "minimal"

        [profiles.deep]
        model_reasoning_effort = "xhigh"
        """

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertEqual(effort, .low)
    }

    func testProfileOnlyValueIsNotReportedAsTopLevel() async {
        let content = """
        model_provider = "cliproxyapi"

        [profiles.work]
        model_reasoning_effort = "minimal"
        """

        // Nothing at the top level: the caller must keep its default rather than
        // adopt (and later write back) the profile's value.
        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertNil(effort)
    }

    func testArrayOfTablesEndsTheTopLevelRegion() async {
        let content = """
        model = "gpt-5-codex"

        [[mcp_servers]]
        model_reasoning_effort = "ultra"
        """

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertNil(effort)
    }

    func testMissingKeyReturnsNil() async {
        let content = """
        model_provider = "cliproxyapi"
        model = "gpt-5-codex"
        """

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertNil(effort)
    }

    func testCommentedKeyIsIgnored() async {
        let content = """
        # model_reasoning_effort = "minimal"
          #model_reasoning_effort = "low"
        model = "gpt-5-codex"
        """

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertNil(effort)
    }

    func testKeyInsideMultiLineStringIsIgnored() async {
        let content = """
        notify = \"\"\"
        model_reasoning_effort = "minimal"
        [profiles.work]
        \"\"\"
        model_reasoning_effort = "max"
        """

        // The string body must not be read as a key, and the `[profiles.work]`
        // line inside it must not end the top-level region.
        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertEqual(effort, .max)
    }

    func testTrailingCommentIsNotPartOfTheValue() async {
        let content = #"model_reasoning_effort = "ultra"  # deepest"#

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertEqual(effort, .ultra)
    }

    func testQuotedKeyIsRecognised() async {
        let content = #""model_reasoning_effort" = "none""#

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertEqual(effort, CodexReasoningEffort.none)
    }

    func testLiteralStringValueIsRead() async {
        let content = "model_reasoning_effort = 'ultra'"

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertEqual(effort, .ultra)
    }

    func testSimilarlyNamedKeysAreNotMatched() async {
        let content = """
        model_reasoning_effort_override = "minimal"
        plan_mode_reasoning_effort = "low"
        """

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertNil(effort)
    }

    func testEmptyValueParsesAsNoValue() async {
        let content = #"model_reasoning_effort = """#

        let effort = await service.parseTopLevelCodexReasoningEffort(from: content)
        XCTAssertNil(effort)
    }

    // MARK: - Managed TOML Generation

    func testManagedTOMLEmitsSelectedReasoningEffort() async {
        for effort in CodexReasoningEffort.allCases {
            let toml = await service.buildManagedCodexTOML(
                model: "gpt-5-codex",
                proxyURL: proxyURL,
                reasoningEffort: effort
            )

            XCTAssertTrue(
                toml.contains("model_reasoning_effort = \"\(effort.rawValue)\""),
                "Expected managed TOML to contain effort \(effort.rawValue)"
            )
        }
    }

    func testManagedTOMLDefaultsToHighReasoningEffort() async {
        let toml = await service.buildManagedCodexTOML(model: "gpt-5-codex", proxyURL: proxyURL)

        XCTAssertTrue(toml.contains("model_reasoning_effort = \"high\""))
    }

    func testManagedTOMLEscapesCustomReasoningEffort() async {
        let toml = await service.buildManagedCodexTOML(
            model: "gpt-5-codex",
            proxyURL: proxyURL,
            reasoningEffort: .custom("we\"ird")
        )

        XCTAssertTrue(toml.contains(#"model_reasoning_effort = "we\"ird""#))
    }

    func testDefaultConfigurationUsesHighReasoningEffort() {
        let config = AgentConfiguration(
            agent: .codexCLI,
            proxyURL: proxyURL,
            apiKey: "quotio-test-key"
        )

        XCTAssertEqual(config.codexReasoningEffort, .high)
        XCTAssertEqual(CodexReasoningEffort.defaultEffort, .high)
    }

    // MARK: - Open → Save Is Non-Destructive
    //
    // Reproduces what the sheet does: read the existing config, seed the picker
    // with what was read, then save without touching the picker.

    private func openThenSave(existing: String, model: String = "gpt-5-codex") async -> String {
        let effort = await service.parseTopLevelCodexReasoningEffort(from: existing)
            ?? .defaultEffort
        let managed = await service.buildManagedCodexTOML(
            model: model,
            proxyURL: proxyURL,
            reasoningEffort: effort
        )
        return await service.mergeCodexConfig(existingContent: existing, managedConfig: managed)
    }

    func testOpenThenSavePreservesUnknownTopLevelValue() async {
        for value in ["none", "max", "ultra", "turbo"] {
            let existing = """
            model_provider = "cliproxyapi"
            model = "gpt-5-codex"
            model_reasoning_effort = "\(value)"
            """

            let merged = await openThenSave(existing: existing)

            XCTAssertTrue(
                merged.contains("model_reasoning_effort = \"\(value)\""),
                "Saving must preserve the existing value \(value)"
            )
            let reread = await service.parseTopLevelCodexReasoningEffort(from: merged)
            XCTAssertEqual(reread?.rawValue, value)
        }
    }

    func testOpenThenSaveDoesNotAdoptProfileValue() async {
        let existing = """
        model_provider = "cliproxyapi"
        model = "gpt-5-codex"
        model_reasoning_effort = "ultra"

        [profiles.work]
        model_reasoning_effort = "minimal"
        """

        let merged = await openThenSave(existing: existing)

        // The top-level setting survives...
        let mergedEffort = await service.parseTopLevelCodexReasoningEffort(from: merged)
        XCTAssertEqual(mergedEffort, .ultra)
        // ...and the profile is left exactly as the user wrote it.
        XCTAssertTrue(merged.contains("[profiles.work]"))
        XCTAssertTrue(merged.contains("model_reasoning_effort = \"minimal\""))
    }

    func testOpenThenSaveWithNoTopLevelKeyWritesTheDefault() async {
        let existing = """
        approval_policy = "never"

        [profiles.work]
        model_reasoning_effort = "minimal"
        """

        let merged = await openThenSave(existing: existing)

        let mergedEffort = await service.parseTopLevelCodexReasoningEffort(from: merged)
        XCTAssertEqual(mergedEffort, .high)
        XCTAssertTrue(merged.contains("approval_policy = \"never\""))
        XCTAssertTrue(merged.contains("model_reasoning_effort = \"minimal\""))
    }

    func testOpenThenSavePreservesMultiLineStringBodies() async {
        let existing = """
        model_reasoning_effort = "ultra"
        notify = \"\"\"
        model = "do not touch"
        model_provider = "do not touch either"
        \"\"\"
        """

        let merged = await openThenSave(existing: existing)

        XCTAssertTrue(merged.contains(#"model = "do not touch""#))
        XCTAssertTrue(merged.contains(#"model_provider = "do not touch either""#))
        let mergedEffort = await service.parseTopLevelCodexReasoningEffort(from: merged)
        XCTAssertEqual(mergedEffort, .ultra)
    }

    // MARK: - Managed-Key Merge

    func testMergeReplacesManagedReasoningEffortAndPreservesUserKeys() async {
        let existing = """
        # user banner
        approval_policy = "never"
        model_provider = "cliproxyapi"
        model = "gpt-5-codex"
        model_reasoning_effort = "high"

        [profiles.fast]
        model = "gpt-5-codex-mini"
        """

        let managed = await service.buildManagedCodexTOML(
            model: "gpt-5.1-codex-max",
            proxyURL: proxyURL,
            reasoningEffort: .xhigh
        )

        let merged = await service.mergeCodexConfig(
            existingContent: existing,
            managedConfig: managed
        )

        // Managed keys are replaced with the newly selected values
        XCTAssertTrue(merged.contains("model_reasoning_effort = \"xhigh\""))
        XCTAssertFalse(merged.contains("model_reasoning_effort = \"high\""))
        XCTAssertTrue(merged.contains("model = \"gpt-5.1-codex-max\""))

        // User content survives the merge
        XCTAssertTrue(merged.contains("approval_policy = \"never\""))
        XCTAssertTrue(merged.contains("[profiles.fast]"))
        XCTAssertTrue(merged.contains("model = \"gpt-5-codex-mini\""))
    }

    func testMergeEmitsSingleTopLevelReasoningEffortKey() async {
        let existing = """
        model_reasoning_effort = "low"
        custom_key = "value"
        """

        let managed = await service.buildManagedCodexTOML(
            model: "gpt-5-codex",
            proxyURL: proxyURL,
            reasoningEffort: .medium
        )

        let merged = await service.mergeCodexConfig(
            existingContent: existing,
            managedConfig: managed
        )

        let occurrences = merged
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model_reasoning_effort") }

        XCTAssertEqual(occurrences.count, 1)
        XCTAssertTrue(merged.contains("model_reasoning_effort = \"medium\""))
        XCTAssertTrue(merged.contains("custom_key = \"value\""))
    }
}
