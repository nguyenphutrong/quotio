import XCTest
@testable import Quotio

final class CodexReasoningEffortTests: XCTestCase {
    private let service = AgentConfigurationService()

    // MARK: - Managed TOML Generation

    func testManagedTOMLEmitsSelectedReasoningEffort() async {
        for effort in CodexReasoningEffort.allCases {
            let toml = await service.buildManagedCodexTOML(
                model: "gpt-5-codex",
                proxyURL: "http://127.0.0.1:8317/v1",
                reasoningEffort: effort
            )

            XCTAssertTrue(
                toml.contains("model_reasoning_effort = \"\(effort.rawValue)\""),
                "Expected managed TOML to contain effort \(effort.rawValue)"
            )
        }
    }

    func testManagedTOMLDefaultsToHighReasoningEffort() async {
        let toml = await service.buildManagedCodexTOML(
            model: "gpt-5-codex",
            proxyURL: "http://127.0.0.1:8317/v1"
        )

        XCTAssertTrue(toml.contains("model_reasoning_effort = \"high\""))
    }

    func testDefaultConfigurationUsesHighReasoningEffort() {
        let config = AgentConfiguration(
            agent: .codexCLI,
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "quotio-test-key"
        )

        XCTAssertEqual(config.codexReasoningEffort, .high)
        XCTAssertEqual(CodexReasoningEffort.defaultEffort, .high)
    }

    func testReasoningEffortRawValuesMatchCodexCLI() {
        XCTAssertEqual(
            CodexReasoningEffort.allCases.map(\.rawValue),
            ["minimal", "low", "medium", "high", "xhigh"]
        )
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
            proxyURL: "http://127.0.0.1:8317/v1",
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

    func testMergeEmitsSingleReasoningEffortKey() async {
        let existing = """
        model_reasoning_effort = "low"
        custom_key = "value"
        """

        let managed = await service.buildManagedCodexTOML(
            model: "gpt-5-codex",
            proxyURL: "http://127.0.0.1:8317/v1",
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
