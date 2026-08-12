import XCTest
@testable import Quotio

// MARK: - Test Double

private actor StubAgentConfigReverter: AgentConfigReverting {
    enum Behavior: Sendable {
        case succeeds
        case fails(String)
        case throwsError(String)
    }

    struct StubError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let configuredAgents: Set<CLIAgent>
    private let behaviors: [CLIAgent: Behavior]
    private(set) var revertedAgents: [CLIAgent] = []

    init(configuredAgents: Set<CLIAgent>, behaviors: [CLIAgent: Behavior] = [:]) {
        self.configuredAgents = configuredAgents
        self.behaviors = behaviors
    }

    func isConfiguredForQuotioProxy(agent: CLIAgent) -> Bool {
        configuredAgents.contains(agent)
    }

    func revertToDefault(agent: CLIAgent) async throws -> AgentConfigResult {
        revertedAgents.append(agent)

        switch behaviors[agent] ?? .succeeds {
        case .succeeds:
            return .success(type: .file, mode: .automatic, instructions: "reverted", modelsConfigured: 0)
        case .fails(let message):
            return .failure(error: message)
        case .throwsError(let message):
            throw StubError(message: message)
        }
    }
}

// MARK: - Tests

final class AgentQuitRestoreTests: XCTestCase {

    // MARK: Setting round-trip

    func testRestoreOnQuitSettingDefaultsToDisabled() throws {
        let defaults = try makeIsolatedDefaults(#function)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertFalse(AgentQuitRestoreSettings(defaults: defaults).isEnabled)
    }

    func testRestoreOnQuitSettingRoundTrips() throws {
        let defaults = try makeIsolatedDefaults(#function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let settings = AgentQuitRestoreSettings(defaults: defaults)
        settings.isEnabled = true
        XCTAssertTrue(AgentQuitRestoreSettings(defaults: defaults).isEnabled)
        XCTAssertTrue(defaults.bool(forKey: AgentQuitRestoreSettings.storageKey))

        settings.isEnabled = false
        XCTAssertFalse(AgentQuitRestoreSettings(defaults: defaults).isEnabled)
    }

    // MARK: Orchestration

    func testOnlyQuotioConfiguredAgentsAreReverted() async {
        let reverter = StubAgentConfigReverter(configuredAgents: [.claudeCode, .openCode])
        let service = AgentQuitRestoreService(reverter: reverter)

        let outcome = await service.restoreConfiguredAgents(
            agents: [.claudeCode, .codexCLI, .ampCLI, .openCode]
        )

        XCTAssertEqual(outcome.reverted, [.claudeCode, .openCode])
        XCTAssertEqual(outcome.skipped, [.codexCLI, .ampCLI])
        XCTAssertTrue(outcome.failures.isEmpty)

        let touched = await reverter.revertedAgents
        XCTAssertEqual(touched, [.claudeCode, .openCode])
    }

    func testNothingIsRevertedWhenNoAgentUsesTheProxy() async {
        let reverter = StubAgentConfigReverter(configuredAgents: [])
        let service = AgentQuitRestoreService(reverter: reverter)

        let outcome = await service.restoreConfiguredAgents(agents: CLIAgent.allCases)

        XCTAssertTrue(outcome.reverted.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.skipped, CLIAgent.allCases)

        let touched = await reverter.revertedAgents
        XCTAssertTrue(touched.isEmpty)
    }

    func testAgentsAddedLaterAreCoveredByAllCases() async {
        // The quit handler iterates CLIAgent.allCases, so a newly added agent is
        // picked up without touching the orchestration.
        let reverter = StubAgentConfigReverter(configuredAgents: Set(CLIAgent.allCases))
        let service = AgentQuitRestoreService(reverter: reverter)

        let outcome = await service.restoreConfiguredAgents()

        XCTAssertEqual(Set(outcome.reverted), Set(CLIAgent.allCases))
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    // MARK: Failure isolation

    func testUnsuccessfulRevertDoesNotStopRemainingAgents() async {
        let reverter = StubAgentConfigReverter(
            configuredAgents: [.claudeCode, .codexCLI, .openCode],
            behaviors: [.codexCLI: .fails("permission denied")]
        )
        let service = AgentQuitRestoreService(reverter: reverter)

        let outcome = await service.restoreConfiguredAgents(
            agents: [.claudeCode, .codexCLI, .openCode]
        )

        XCTAssertEqual(outcome.reverted, [.claudeCode, .openCode])
        XCTAssertEqual(
            outcome.failures,
            [AgentQuitRestoreFailure(agent: .codexCLI, message: "permission denied")]
        )

        let touched = await reverter.revertedAgents
        XCTAssertEqual(touched, [.claudeCode, .codexCLI, .openCode])
    }

    func testThrownRevertErrorIsRecordedAndOthersStillRun() async {
        let reverter = StubAgentConfigReverter(
            configuredAgents: [.claudeCode, .codexCLI, .factoryDroid],
            behaviors: [.claudeCode: .throwsError("disk full")]
        )
        let service = AgentQuitRestoreService(reverter: reverter)

        let outcome = await service.restoreConfiguredAgents(
            agents: [.claudeCode, .codexCLI, .factoryDroid]
        )

        XCTAssertEqual(outcome.reverted, [.codexCLI, .factoryDroid])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.agent, .claudeCode)
        XCTAssertEqual(outcome.failures.first?.message, "disk full")
    }

    func testSummaryReportsRevertedAndFailedAgents() async {
        let reverter = StubAgentConfigReverter(
            configuredAgents: [.claudeCode, .codexCLI],
            behaviors: [.codexCLI: .fails("bad toml")]
        )
        let service = AgentQuitRestoreService(reverter: reverter)

        let outcome = await service.restoreConfiguredAgents(agents: [.claudeCode, .codexCLI])

        XCTAssertTrue(outcome.summary.contains("claude-code"))
        XCTAssertTrue(outcome.summary.contains("codex: bad toml"))
    }

    // MARK: Helpers

    private func makeIsolatedDefaults(_ suiteName: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
