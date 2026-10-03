import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

/// Codex keeps its single model in the sonnet slot, and the configuration it writes has
/// to carry whatever the picker chose — otherwise the agent is pointed at the proxy
/// while still asking for a model the proxy does not serve.
final class CodexModelSelectionTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testTheChosenModelReachesTheCodexConfiguration() {
    var configuration = AgentConfiguration(
      agent: .codexCLI, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "key")
    configuration.modelSlots[.sonnet] = "muse-spark-1.3"

    let rendered = CodexConfigurationCodec.managedTOML(
      model: configuration.modelSlots[.sonnet] ?? "gpt-5-codex",
      proxyURL: configuration.proxyURL,
      reasoningEffort: configuration.codexReasoningEffort
    )

    XCTAssertTrue(rendered.contains(#"model = "muse-spark-1.3""#), rendered)
    XCTAssertTrue(rendered.contains(#"model_provider = "cliproxyapi""#), rendered)
    XCTAssertTrue(rendered.contains(#"wire_api = "responses""#), rendered)
  }

  /// A fresh Codex configuration must not inherit the Anthropic tier defaults: those
  /// belong to Claude Code's slots, and writing one into Codex's single `model` key
  /// would point it at a Claude id nobody chose.
  func testAFreshCodexConfigurationDoesNotInheritClaudeSlotDefaults() {
    let configuration = AgentConfiguration(
      agent: .codexCLI, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "key")

    XCTAssertEqual(configuration.modelSlots, [.sonnet: AgentConfiguration.defaultCodexModel])

    let rendered = CodexConfigurationCodec.managedTOML(
      model: configuration.modelSlots[.sonnet] ?? "gpt-5-codex",
      proxyURL: configuration.proxyURL,
      reasoningEffort: configuration.codexReasoningEffort
    )

    XCTAssertTrue(rendered.contains(#"model = "gpt-5-codex""#), rendered)
  }

  func testClaudeCodeKeepsItsTierDefaults() {
    let configuration = AgentConfiguration(
      agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "key")

    XCTAssertEqual(Set(configuration.modelSlots.keys), Set(ModelSlot.allCases))
  }

  /// Reading an existing config back must surface the model in the same slot the picker
  /// binds to, so an already-configured agent opens showing what it actually uses.
  func testAnExistingModelIsReadBackIntoTheSlotThePickerBindsTo() {
    let existing = """
      model_provider = "cliproxyapi"
      model = "muse-spark-1.3"
      model_reasoning_effort = "medium"

      [model_providers.cliproxyapi]
      name = "cliproxyapi"
      base_url = "http://127.0.0.1:8317/v1"
      wire_api = "responses"
      """

    let snapshot = CodexConfigurationCodec.snapshot(from: existing)

    XCTAssertEqual(snapshot.model, "muse-spark-1.3")
  }
}
