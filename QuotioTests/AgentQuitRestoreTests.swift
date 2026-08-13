import XCTest
@testable import Quotio

// MARK: - Test Doubles

private actor StubAgentConfigReverter: AgentConfigReverting {
    enum Behavior: Sendable {
        case succeeds
        case fails(String)
        case throwsError(String)
        /// Never returns, standing in for a wedged filesystem call.
        case hangs
    }

    struct StubError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let behaviors: [CLIAgent: Behavior]
    private(set) var revertedAgents: [CLIAgent] = []

    init(behaviors: [CLIAgent: Behavior] = [:]) {
        self.behaviors = behaviors
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
        case .hangs:
            try await Task.sleep(for: .seconds(600))
            return .failure(error: "unreachable")
        }
    }
}

private struct StubOwnershipResolver: AgentConfigOwnershipResolving {
    var decisions: [CLIAgent: AgentConfigOwnership] = [:]
    var fallback: AgentConfigOwnership = .notOwned(.noEvidence)

    func ownership(of agent: CLIAgent) -> AgentConfigOwnership {
        decisions[agent] ?? fallback
    }

    static func owningAll(_ agents: [CLIAgent]) -> StubOwnershipResolver {
        StubOwnershipResolver(
            decisions: Dictionary(uniqueKeysWithValues: agents.map { ($0, .owned(.receipt)) })
        )
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

    // MARK: Ownership gating

    func testOnlyAgentsQuotioOwnsAreReverted() async {
        let reverter = StubAgentConfigReverter()
        let ownership = StubOwnershipResolver(
            decisions: [
                .claudeCode: .owned(.receipt),
                .codexCLI: .notOwned(.externallyModified),
                .ampCLI: .notOwned(.noEvidence),
                .openCode: .owned(.authoredMarker)
            ]
        )
        let service = AgentQuitRestoreService(reverter: reverter, ownership: ownership)

        let outcome = await service.restoreConfiguredAgents(
            agents: [.claudeCode, .codexCLI, .ampCLI, .openCode]
        )

        XCTAssertEqual(outcome.reverted, [.claudeCode, .openCode])
        XCTAssertEqual(
            outcome.skipped,
            [
                AgentQuitRestoreSkip(agent: .codexCLI, reason: .externallyModified),
                AgentQuitRestoreSkip(agent: .ampCLI, reason: .noEvidence)
            ]
        )
        XCTAssertTrue(outcome.failures.isEmpty)

        // The decisive assertion: an unowned config is never handed to the reverter.
        let touched = await reverter.revertedAgents
        XCTAssertEqual(touched, [.claudeCode, .openCode])
    }

    func testNothingIsRevertedWhenOwnershipCannotBeProven() async {
        let reverter = StubAgentConfigReverter()
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver(fallback: .notOwned(.noEvidence))
        )

        let outcome = await service.restoreConfiguredAgents(agents: CLIAgent.allCases)

        XCTAssertTrue(outcome.reverted.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.agent), CLIAgent.allCases)

        let touched = await reverter.revertedAgents
        XCTAssertTrue(touched.isEmpty)
    }

    func testAgentsAddedLaterAreCoveredByAllCases() async {
        let reverter = StubAgentConfigReverter()
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver.owningAll(CLIAgent.allCases)
        )

        let outcome = await service.restoreConfiguredAgents()

        XCTAssertEqual(Set(outcome.reverted), Set(CLIAgent.allCases))
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    // MARK: Failure isolation

    func testUnsuccessfulRevertDoesNotStopRemainingAgents() async {
        let reverter = StubAgentConfigReverter(behaviors: [.codexCLI: .fails("permission denied")])
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver.owningAll([.claudeCode, .codexCLI, .openCode])
        )

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
        let reverter = StubAgentConfigReverter(behaviors: [.claudeCode: .throwsError("disk full")])
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver.owningAll([.claudeCode, .codexCLI, .factoryDroid])
        )

        let outcome = await service.restoreConfiguredAgents(
            agents: [.claudeCode, .codexCLI, .factoryDroid]
        )

        XCTAssertEqual(outcome.reverted, [.codexCLI, .factoryDroid])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.agent, .claudeCode)
        XCTAssertEqual(outcome.failures.first?.message, "disk full")
    }

    func testSummaryReportsRevertedSkippedAndFailedAgents() async {
        let reverter = StubAgentConfigReverter(behaviors: [.codexCLI: .fails("bad toml")])
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver(
                decisions: [
                    .claudeCode: .owned(.receipt),
                    .codexCLI: .owned(.receipt),
                    .ampCLI: .notOwned(.externallyModified)
                ]
            )
        )

        let outcome = await service.restoreConfiguredAgents(agents: [.claudeCode, .codexCLI, .ampCLI])

        XCTAssertTrue(outcome.summary.contains("claude-code"))
        XCTAssertTrue(outcome.summary.contains("codex: bad toml"))
        XCTAssertTrue(outcome.summary.contains("amp: externallyModified"))
    }

    // MARK: Termination coordination

    @MainActor
    func testTerminationReplyWaitsForEveryAgentBeforeFiring() async {
        let reverter = StubAgentConfigReverter()
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver.owningAll(CLIAgent.allCases)
        )

        let replied = expectation(description: "reply delivered")
        let results = ResultBox()

        let coordinator = AgentQuitRestoreTerminationCoordinator(
            timeout: .seconds(30),
            restore: { progress in
                await service.restoreConfiguredAgents(progress: progress)
            },
            onResolved: { result in
                results.append(result)
                replied.fulfill()
            }
        )
        coordinator.begin()

        await fulfillment(of: [replied], timeout: 10)

        let recorded = results.all()
        XCTAssertEqual(recorded.count, 1)
        guard case .completed(let outcome) = recorded[0] else {
            return XCTFail("expected completion, got \(recorded[0])")
        }
        // All agents finished *before* the reply that lets AppKit kill the process.
        XCTAssertEqual(Set(outcome.reverted), Set(CLIAgent.allCases))
    }

    @MainActor
    func testWedgedAgentStillRepliesOnTimeoutWithPartialProgress() async {
        // claudeCode reverts, codexCLI never returns. Without a watchdog the app
        // would sit in .terminateLater forever and need a force quit.
        let reverter = StubAgentConfigReverter(behaviors: [.codexCLI: .hangs])
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver.owningAll([.claudeCode, .codexCLI, .openCode])
        )

        let replied = expectation(description: "reply delivered")
        let results = ResultBox()

        let coordinator = AgentQuitRestoreTerminationCoordinator(
            timeout: .milliseconds(300),
            restore: { progress in
                await service.restoreConfiguredAgents(
                    agents: [.claudeCode, .codexCLI, .openCode],
                    progress: progress
                )
            },
            onResolved: { result in
                results.append(result)
                replied.fulfill()
            }
        )
        coordinator.begin()

        await fulfillment(of: [replied], timeout: 10)

        let recorded = results.all()
        XCTAssertEqual(recorded.count, 1)
        guard case .timedOut(let partial) = recorded[0] else {
            return XCTFail("expected timeout, got \(recorded[0])")
        }
        // The work completed before the wedge is reported, not discarded.
        XCTAssertEqual(partial.reverted, [.claudeCode])
    }

    @MainActor
    func testReplyIsDeliveredExactlyOnceEvenAfterTheTimeoutFires() async {
        // A revert that finishes just after the deadline must not produce a
        // second reply: replying twice to AppKit is undefined behaviour.
        let reverter = StubAgentConfigReverter()
        let service = AgentQuitRestoreService(
            reverter: reverter,
            ownership: StubOwnershipResolver.owningAll([.claudeCode])
        )

        let replied = expectation(description: "reply delivered")
        let results = ResultBox()

        let coordinator = AgentQuitRestoreTerminationCoordinator(
            timeout: .zero,
            restore: { progress in
                await service.restoreConfiguredAgents(agents: [.claudeCode], progress: progress)
            },
            onResolved: { result in
                results.append(result)
                replied.fulfill()
            }
        )
        coordinator.begin()

        await fulfillment(of: [replied], timeout: 10)
        // Give the losing path time to try to resolve as well.
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(results.all().count, 1, "reply(toApplicationShouldTerminate:) must fire exactly once")
    }

    // MARK: Helpers

    private func makeIsolatedDefaults(_ suiteName: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Collects every resolution the coordinator emits so a duplicate reply is
/// visible as a count, not just a crash.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AgentQuitRestoreTerminationResult] = []

    func append(_ result: AgentQuitRestoreTerminationResult) {
        lock.withLock { results.append(result) }
    }

    func all() -> [AgentQuitRestoreTerminationResult] {
        lock.withLock { results }
    }
}
