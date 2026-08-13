//
//  AgentQuitRestoreService.swift
//  Quotio - Restore agent configurations when the app quits
//
//  Opt-in: when enabled, every agent whose on-disk config Quotio can *prove* it
//  wrote is reverted through the same "Use default" path the agent sheet
//  exposes, so the agent falls back to its own subscription once Quotio is gone.
//
//  Two properties matter here and are enforced separately:
//
//  * Ownership - a config is only touched when `AgentConfigOwnership` says
//    Quotio authored what is currently on disk. Pointing at localhost is not
//    ownership; see `AgentConfigOwnership.swift`.
//  * Termination ordering - the app must not die halfway through the revert,
//    and must not hang forever if the revert wedges. That contract lives in
//    `AgentQuitRestoreTerminationCoordinator`, which is deliberately separate
//    from `AppDelegate` so it can be tested without an `NSApplication`.
//

import Foundation

// MARK: - Settings

/// Persistence for the "restore agent configs on quit" preference.
///
/// Default is `false` so existing installs keep their current behaviour: configs
/// stay in place across restarts, which is what users who relaunch Quotio expect.
nonisolated struct AgentQuitRestoreSettings {
    static let storageKey = "restoreAgentConfigsOnQuit"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.storageKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.storageKey) }
    }
}

// MARK: - Revert Abstraction

/// The subset of `AgentConfigurationService` the quit-time orchestration needs.
/// Kept as a protocol so the orchestration can be tested without touching real
/// config files in the user's home directory.
protocol AgentConfigReverting: Sendable {
    /// Runs the agent's existing revert-to-default path.
    func revertToDefault(agent: CLIAgent) async throws -> AgentConfigResult
}

extension AgentConfigurationService: AgentConfigReverting {
    /// Reuses `generateConfiguration` with `setupMode == .defaultSetup`, i.e. the
    /// exact code path behind the per-agent "Default" setup button. Nothing about
    /// the revert logic (including backups) is duplicated here.
    func revertToDefault(agent: CLIAgent) async throws -> AgentConfigResult {
        let config = AgentConfiguration(
            agent: agent,
            proxyURL: "",
            apiKey: "",
            setupMode: .defaultSetup
        )

        return try await generateConfiguration(
            agent: agent,
            config: config,
            mode: .automatic,
            detectionService: AgentDetectionService()
        )
    }
}

// MARK: - Ownership Abstraction

/// Answers "did Quotio write what is on disk for this agent right now?".
nonisolated protocol AgentConfigOwnershipResolving: Sendable {
    func ownership(of agent: CLIAgent) -> AgentConfigOwnership
}

/// Production resolver: receipt first, Quotio-authored file marker as fallback.
nonisolated struct DefaultAgentConfigOwnershipResolver: AgentConfigOwnershipResolving {
    private let store: AgentConfigOwnershipStore
    private let verifier: AgentConfigOwnershipVerifier

    init(
        store: AgentConfigOwnershipStore = AgentConfigOwnershipStore(),
        verifier: AgentConfigOwnershipVerifier = AgentConfigOwnershipVerifier()
    ) {
        self.store = store
        self.verifier = verifier
    }

    func ownership(of agent: CLIAgent) -> AgentConfigOwnership {
        verifier.ownership(of: agent, record: store.record(for: agent))
    }
}

// MARK: - Outcome

nonisolated struct AgentQuitRestoreFailure: Sendable, Equatable {
    let agent: CLIAgent
    let message: String
}

nonisolated struct AgentQuitRestoreSkip: Sendable, Equatable {
    let agent: CLIAgent
    let reason: AgentConfigOwnershipDoubt
}

nonisolated struct AgentQuitRestoreOutcome: Sendable, Equatable {
    /// Agents whose Quotio proxy config was successfully removed.
    var reverted: [CLIAgent] = []
    /// Agents Quotio could not prove it owned, so nothing was touched.
    var skipped: [AgentQuitRestoreSkip] = []
    /// Agents whose revert failed. Failures never stop the remaining agents.
    var failures: [AgentQuitRestoreFailure] = []

    var summary: String {
        let revertedList = reverted.map(\.rawValue).joined(separator: ", ")
        let skippedList = skipped.map { "\($0.agent.rawValue): \($0.reason.rawValue)" }.joined(separator: "; ")
        let failedList = failures.map { "\($0.agent.rawValue): \($0.message)" }.joined(separator: "; ")
        return "reverted=[\(revertedList)] skipped=[\(skippedList)] failed=[\(failedList)]"
    }
}

// MARK: - Progress

/// Lets a caller read how far a run got without waiting for it to finish, so a
/// timeout can report what was actually completed instead of just "gave up".
///
/// Lock-based rather than actor-isolated on purpose: the watchdog must be able
/// to read progress even while the restore loop is inside a blocking
/// filesystem call.
nonisolated final class AgentQuitRestoreProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome = AgentQuitRestoreOutcome()

    init() {}

    func snapshot() -> AgentQuitRestoreOutcome {
        lock.withLock { outcome }
    }

    fileprivate func update(_ body: (inout AgentQuitRestoreOutcome) -> Void) {
        lock.withLock { body(&outcome) }
    }
}

// MARK: - Service

/// Orchestrates the quit-time revert across every known agent.
///
/// Deliberately a `Sendable` class rather than an `actor`: the watchdog in
/// `AgentQuitRestoreTerminationCoordinator` must never queue behind this work,
/// and actor reentrancy would let a wedged revert block a progress read.
nonisolated final class AgentQuitRestoreService: Sendable {
    static let shared = AgentQuitRestoreService(
        reverter: AgentConfigurationService(),
        ownership: DefaultAgentConfigOwnershipResolver()
    )

    private let reverter: AgentConfigReverting
    private let ownership: AgentConfigOwnershipResolving

    init(reverter: AgentConfigReverting, ownership: AgentConfigOwnershipResolving) {
        self.reverter = reverter
        self.ownership = ownership
    }

    /// Reverts every agent Quotio can prove it configured for its proxy.
    ///
    /// Agents are handled independently: a thrown error or an unsuccessful result
    /// for one agent is recorded and the loop continues, so a single broken config
    /// can never block the rest of the revert (or app termination).
    @discardableResult
    func restoreConfiguredAgents(
        agents: [CLIAgent] = CLIAgent.allCases,
        progress: AgentQuitRestoreProgress = AgentQuitRestoreProgress()
    ) async -> AgentQuitRestoreOutcome {
        for agent in agents {
            let decision = ownership.ownership(of: agent)

            guard case .owned(let proof) = decision else {
                if case .notOwned(let doubt) = decision {
                    progress.update { $0.skipped.append(AgentQuitRestoreSkip(agent: agent, reason: doubt)) }
                }
                continue
            }

            Log.debug("Quit restore: \(agent.rawValue) ownership proven via \(proof.rawValue)")

            do {
                let result = try await reverter.revertToDefault(agent: agent)
                if result.success {
                    progress.update { $0.reverted.append(agent) }
                } else {
                    progress.update {
                        $0.failures.append(
                            AgentQuitRestoreFailure(agent: agent, message: result.error ?? "unknown error")
                        )
                    }
                }
            } catch {
                progress.update {
                    $0.failures.append(
                        AgentQuitRestoreFailure(agent: agent, message: error.localizedDescription)
                    )
                }
            }
        }

        return progress.snapshot()
    }
}

// MARK: - Termination Coordination

nonisolated enum AgentQuitRestoreTerminationResult: Sendable, Equatable {
    /// Every agent was processed before the deadline.
    case completed(AgentQuitRestoreOutcome)
    /// The deadline was reached first. Carries whatever finished by then, so the
    /// log names the agents that were left alone rather than just reporting a
    /// timeout.
    case timedOut(partial: AgentQuitRestoreOutcome)

    var outcome: AgentQuitRestoreOutcome {
        switch self {
        case .completed(let outcome), .timedOut(let outcome): return outcome
        }
    }
}

/// Holds AppKit's termination decision open until the revert finishes, and
/// guarantees the decision is delivered exactly once.
///
/// `applicationShouldTerminate` returns `.terminateLater`, which means AppKit
/// waits indefinitely until `reply(toApplicationShouldTerminate:)` is called.
/// Never replying is worse than the bug this feature fixes - the app would hang
/// and the user would have to force quit - so a watchdog replies on a deadline
/// even if the restore is wedged. Whichever path gets there first wins; the
/// other becomes a no-op.
///
/// Everything runs on the main actor, which is both where AppKit requires the
/// reply and what makes "exactly once" hold without a lock.
@MainActor
final class AgentQuitRestoreTerminationCoordinator {
    /// How long termination may be held open. Long enough for five agents'
    /// worth of small file rewrites, short enough to stay well inside the
    /// shorter OS budget for a logout/restart-initiated quit.
    static let defaultTimeout: Duration = .seconds(5)

    private let timeout: Duration
    private let restore: @Sendable (AgentQuitRestoreProgress) async -> AgentQuitRestoreOutcome
    private let onResolved: @MainActor (AgentQuitRestoreTerminationResult) -> Void
    private var hasResolved = false

    init(
        timeout: Duration = AgentQuitRestoreTerminationCoordinator.defaultTimeout,
        restore: @escaping @Sendable (AgentQuitRestoreProgress) async -> AgentQuitRestoreOutcome,
        onResolved: @escaping @MainActor (AgentQuitRestoreTerminationResult) -> Void
    ) {
        self.timeout = timeout
        self.restore = restore
        self.onResolved = onResolved
    }

    /// Starts the revert and the watchdog. Returns immediately; the caller
    /// should hand `.terminateLater` back to AppKit.
    func begin() {
        let progress = AgentQuitRestoreProgress()
        let restore = self.restore
        let timeout = self.timeout

        // Both tasks capture `self` strongly on purpose: the reply must still be
        // delivered if the caller drops its reference to the coordinator, and a
        // dropped reply would hang the app rather than merely skip the revert.
        Task { @MainActor in
            let outcome = await restore(progress)
            self.resolve(.completed(outcome))
        }

        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            self.resolve(.timedOut(partial: progress.snapshot()))
        }
    }

    private func resolve(_ result: AgentQuitRestoreTerminationResult) {
        guard !hasResolved else { return }
        hasResolved = true
        onResolved(result)
    }
}
