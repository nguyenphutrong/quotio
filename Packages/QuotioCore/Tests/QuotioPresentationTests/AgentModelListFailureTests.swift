import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

/// The model list shown while routing through the proxy must be the proxy's own. A
/// built-in list substituted on failure reads as availability and gets written into the
/// agent's config, where it fails at the first request.
@MainActor
final class AgentModelListFailureTests: XCTestCase {
  func testProxyModeShowsNoModelsAndSaysWhyWhenTheRosterCannotBeRead() async {
    let model = makeModel(catalog: FailingAgentService())

    let loaded = await model.loadModels()

    XCTAssertFalse(loaded)
    XCTAssertTrue(model.availableModels.isEmpty, "a canned list must not stand in")
    guard case .unreachable = model.modelListFailure else {
      return XCTFail("expected an unreachable failure, got \(String(describing: model.modelListFailure))")
    }
  }

  func testDirectModeStillFallsBackToTheBuiltInList() async {
    let model = makeModel(catalog: FailingAgentService())

    await model.selectSetupMode(.defaultSetup)

    XCTAssertFalse(model.availableModels.isEmpty, "no proxy exists to ask in direct mode")
    XCTAssertNil(model.modelListFailure)
  }

  func testAnEmptyRosterIsReportedRatherThanPaperedOver() async {
    let model = makeModel(catalog: EmptyAgentService())

    let loaded = await model.loadModels()

    XCTAssertFalse(loaded)
    XCTAssertTrue(model.availableModels.isEmpty)
    XCTAssertEqual(model.modelListFailure, .emptyRoster)
  }

  func testASuccessfulLoadClearsTheFailure() async {
    let model = makeModel(catalog: ServingAgentService())

    let loaded = await model.loadModels()

    XCTAssertTrue(loaded)
    XCTAssertEqual(model.availableModels.map(\.name), ["muse-spark-1.3"])
    XCTAssertNil(model.modelListFailure)
  }

  /// The built-in list the direct setup falls back to must not survive a switch to the
  /// proxy: it was never the proxy's answer, and on screen it is indistinguishable from
  /// one.
  func testSwitchingToProxyDropsTheListTheDirectSetupFellBackTo() async {
    let model = makeModel(catalog: FailingAgentService())
    await model.selectSetupMode(.defaultSetup)
    XCTAssertFalse(model.availableModels.isEmpty)

    await model.selectSetupMode(.proxy)

    XCTAssertTrue(model.availableModels.isEmpty, "the built-in list must not carry over")
    guard case .unreachable = model.modelListFailure else {
      return XCTFail("expected an unreachable failure, got \(String(describing: model.modelListFailure))")
    }
  }

  /// A stopped proxy hides the roster, not the configuration: what the agent is set to
  /// use is on disk and stays readable.
  func testTheModelCodexHasSavedStaysVisibleWithoutTheProxy() {
    let model = makeModel(catalog: FailingAgentService())
    model.startConfiguration(for: .codexCLI)

    let saved = model.savedModelSlots
    XCTAssertEqual(saved.map(\.slot), [.sonnet], "Codex keeps its one model in the sonnet slot")
    XCTAssertEqual(saved.first?.model, AgentConfiguration.defaultCodexModel)
  }

  func testTheModelsClaudeCodeHasSavedStayVisibleWithoutTheProxy() {
    let model = makeModel(catalog: FailingAgentService())
    model.startConfiguration(for: .claudeCode)

    XCTAssertEqual(model.savedModelSlots.map(\.slot), ModelSlot.allCases)
    XCTAssertFalse(model.savedModelSlots.contains { $0.model.isEmpty })
  }

  func testASlotWithNothingSavedIsNotShownAsSaved() {
    let model = makeModel(catalog: FailingAgentService())
    model.startConfiguration(for: .codexCLI)
    model.currentConfiguration?.modelSlots[.sonnet] = ""

    XCTAssertTrue(model.savedModelSlots.isEmpty, "an empty slot is not a saved model")
  }

  /// The proxy is not listening the instant it is started, so the read that follows the
  /// button must survive the first refusals instead of reporting the proxy as down.
  func testTheReadAfterStartingTheProxyWaitsForItToAnswer() async {
    let catalog = SlowToStartAgentService(failuresBeforeServing: 2)
    let model = makeModel(catalog: catalog)

    await model.loadModelsAfterProxyStart(attempts: 5, delay: .zero)

    XCTAssertNil(model.modelListFailure)
    XCTAssertEqual(model.availableModels.map(\.name), ["muse-spark-1.3"])
    let attempts = await catalog.attempts
    XCTAssertEqual(attempts, 3, "it should stop asking as soon as the proxy answers")
  }

  /// The proxy only hands out its API key once it is up, so the key captured when the
  /// sheet opened is the wrong one for anyone who starts the proxy from inside the sheet.
  func testEachReadUsesTheKeyTheProxyHandsOutNow() async {
    let catalog = RecordingAgentService()
    var key = "before-the-proxy-was-up"
    let model = AgentSetupScreenModel(
      service: AgentConfigurationService(
        adapters: [],
        detector: FailureAgentDetector(),
        shellProfiles: FailureShellProfiles(),
        modelCatalog: catalog
      ),
      endpointContext: { AgentEndpointContext(baseURL: "http://127.0.0.1:8317", apiKey: key) }
    )
    model.startConfiguration(for: .codexCLI)

    _ = await model.loadModels()
    key = "quotio-local-the-real-one"
    _ = await model.loadModels()

    let keysSent = await catalog.keysSent
    XCTAssertEqual(keysSent, ["before-the-proxy-was-up", "quotio-local-the-real-one"])
    XCTAssertEqual(
      model.currentConfiguration?.apiKey, "quotio-local-the-real-one",
      "what gets saved must be the key that just answered")
  }

  private func makeModel(catalog: any AgentModelCatalogRepository) -> AgentSetupScreenModel {
    AgentSetupScreenModel(
      service: AgentConfigurationService(
        adapters: [],
        detector: FailureAgentDetector(),
        shellProfiles: FailureShellProfiles(),
        modelCatalog: catalog
      ),
      endpointContext: { AgentEndpointContext(baseURL: "http://127.0.0.1:8317", apiKey: "k") }
    )
  }
}

private actor FailureAgentDetector: AgentDetecting {
  func detectAll(forceRefresh: Bool) -> [AgentStatus] { [] }
  func detect(_ agent: CLIAgent) -> AgentStatus {
    AgentStatus(
      agent: agent, installed: false, configured: false, binaryPath: nil, version: nil,
      lastConfigured: nil)
  }
  func markConfigured(_ agent: CLIAgent) {}
  func clearConfigured(_ agent: CLIAgent) {}
}

private actor FailureShellProfiles: ShellProfileRepository {
  func detect() -> ShellProfile { ShellProfile(shell: .fish, path: "/tmp/config.fish") }
  func add(configuration: String, for agent: CLIAgent, to profile: ShellProfile) {}
  func removeConfiguration(for agent: CLIAgent, from profile: ShellProfile) {}
}

private actor FailingAgentService: AgentModelCatalogRepository {
  func fetchCatalog(configuration: AgentConfiguration) throws -> [ModelCatalogEntry] {
    throw URLError(.cannotConnectToHost)
  }
  func fetchAvailableModels(configuration: AgentConfiguration) throws -> [AvailableModel] {
    throw URLError(.cannotConnectToHost)
  }
  func testConnection(agent: CLIAgent, configuration: AgentConfiguration) -> ConnectionTestResult {
    ConnectionTestResult(success: false, message: .connected, latencyMs: nil, modelResponded: nil)
  }
}

private actor EmptyAgentService: AgentModelCatalogRepository {
  func fetchCatalog(configuration: AgentConfiguration) -> [ModelCatalogEntry] { [] }
  func fetchAvailableModels(configuration: AgentConfiguration) -> [AvailableModel] { [] }
  func testConnection(agent: CLIAgent, configuration: AgentConfiguration) -> ConnectionTestResult {
    ConnectionTestResult(success: true, message: .connected, latencyMs: nil, modelResponded: nil)
  }
}

private actor ServingAgentService: AgentModelCatalogRepository {
  func fetchCatalog(configuration: AgentConfiguration) -> [ModelCatalogEntry] { [] }
  func fetchAvailableModels(configuration: AgentConfiguration) -> [AvailableModel] {
    [AvailableModel(id: "muse-spark-1.3", name: "muse-spark-1.3", provider: "meta", isDefault: false)]
  }
  func testConnection(agent: CLIAgent, configuration: AgentConfiguration) -> ConnectionTestResult {
    ConnectionTestResult(success: true, message: .connected, latencyMs: nil, modelResponded: nil)
  }
}

/// A proxy that refuses the first reads and then serves its roster, the way one does
/// between the moment it is started and the moment it listens.
private actor SlowToStartAgentService: AgentModelCatalogRepository {
  private(set) var attempts = 0
  private let failuresBeforeServing: Int

  init(failuresBeforeServing: Int) {
    self.failuresBeforeServing = failuresBeforeServing
  }

  func fetchCatalog(configuration: AgentConfiguration) throws -> [ModelCatalogEntry] { [] }

  func fetchAvailableModels(configuration: AgentConfiguration) throws -> [AvailableModel] {
    attempts += 1
    guard attempts > failuresBeforeServing else { throw URLError(.cannotConnectToHost) }
    return [
      AvailableModel(id: "muse-spark-1.3", name: "muse-spark-1.3", provider: "meta", isDefault: false)
    ]
  }

  func testConnection(agent: CLIAgent, configuration: AgentConfiguration) -> ConnectionTestResult {
    ConnectionTestResult(success: true, message: .connected, latencyMs: nil, modelResponded: nil)
  }
}

/// Records the key each read was made with, the way the proxy's access log would.
private actor RecordingAgentService: AgentModelCatalogRepository {
  private(set) var keysSent: [String] = []

  func fetchCatalog(configuration: AgentConfiguration) throws -> [ModelCatalogEntry] { [] }

  func fetchAvailableModels(configuration: AgentConfiguration) throws -> [AvailableModel] {
    keysSent.append(configuration.apiKey)
    return [
      AvailableModel(id: "muse-spark-1.3", name: "muse-spark-1.3", provider: "meta", isDefault: false)
    ]
  }

  func testConnection(agent: CLIAgent, configuration: AgentConfiguration) -> ConnectionTestResult {
    ConnectionTestResult(success: true, message: .connected, latencyMs: nil, modelResponded: nil)
  }
}

/// The picker is on screen before the proxy answers. What it shows and what it saves are
/// two different questions while that is true.
final class ProxyModelSelectionTests: XCTestCase {
  private let roster = [
    AvailableModel(id: "muse-spark-1.3", name: "muse-spark-1.3", provider: "meta", isDefault: false),
    AvailableModel(id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai", isDefault: false),
  ]

  func testNothingIsSavedWhileTheRosterIsStillEmpty() {
    let adopted = ProxyModelSelection.adoption(
      for: "muse-spark-1.3", from: [], preferredFallback: "gpt-5-codex", preferredProvider: "openai")

    XCTAssertNil(adopted, "clearing the saved model would leave a setup that cannot be saved")
  }

  func testAModelTheProxyDoesNotServeIsReplacedOnceTheRosterArrives() {
    let adopted = ProxyModelSelection.adoption(
      for: "gpt-4-turbo", from: roster, preferredFallback: "gpt-5-codex", preferredProvider: "openai")

    XCTAssertEqual(adopted, "gpt-5-codex")
  }

  func testAModelTheProxyServesIsLeftAlone() {
    let adopted = ProxyModelSelection.adoption(
      for: "muse-spark-1.3", from: roster, preferredFallback: "gpt-5-codex", preferredProvider: "openai")

    XCTAssertNil(adopted)
  }

  func testAnEmptySlotTakesTheFallbackTheProxyServes() {
    let adopted = ProxyModelSelection.adoption(
      for: "", from: roster, preferredFallback: "gpt-5-codex", preferredProvider: "openai")

    XCTAssertEqual(adopted, "gpt-5-codex")
  }

  func testWithoutTheFallbackTheOwnerDecidesTheSubstitute() {
    let onlyMeta = [roster[0]]
    XCTAssertEqual(
      ProxyModelSelection.adoption(
        for: "", from: onlyMeta, preferredFallback: "gpt-5-codex", preferredProvider: "openai"),
      "muse-spark-1.3",
      "with no OpenAI model served, the one model there is wins")
  }
}
