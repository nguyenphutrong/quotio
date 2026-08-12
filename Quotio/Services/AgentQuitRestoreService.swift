//
//  AgentQuitRestoreService.swift
//  Quotio - Restore agent configurations when the app quits
//
//  Opt-in: when enabled, every agent whose on-disk config currently points at
//  Quotio's proxy is reverted through the same "Use default" path the agent
//  sheet exposes, so the agent falls back to its own subscription once Quotio
//  is gone.
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
    /// `true` when the agent's saved config currently points at Quotio's proxy.
    func isConfiguredForQuotioProxy(agent: CLIAgent) async -> Bool

    /// Runs the agent's existing revert-to-default path.
    func revertToDefault(agent: CLIAgent) async throws -> AgentConfigResult
}

extension AgentConfigurationService: AgentConfigReverting {
    func isConfiguredForQuotioProxy(agent: CLIAgent) -> Bool {
        readConfiguration(agent: agent)?.isProxyConfigured == true
    }

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

// MARK: - Outcome

nonisolated struct AgentQuitRestoreFailure: Sendable, Equatable {
    let agent: CLIAgent
    let message: String
}

nonisolated struct AgentQuitRestoreOutcome: Sendable, Equatable {
    /// Agents whose Quotio proxy config was successfully removed.
    var reverted: [CLIAgent] = []
    /// Agents that were not configured for Quotio's proxy, so nothing was touched.
    var skipped: [CLIAgent] = []
    /// Agents whose revert failed. Failures never stop the remaining agents.
    var failures: [AgentQuitRestoreFailure] = []

    var summary: String {
        let revertedList = reverted.map(\.rawValue).joined(separator: ", ")
        let failedList = failures.map { "\($0.agent.rawValue): \($0.message)" }.joined(separator: "; ")
        return "reverted=[\(revertedList)] skipped=\(skipped.count) failed=[\(failedList)]"
    }
}

// MARK: - Service

/// Orchestrates the quit-time revert across every known agent.
actor AgentQuitRestoreService {
    static let shared = AgentQuitRestoreService(reverter: AgentConfigurationService())

    private let reverter: AgentConfigReverting

    init(reverter: AgentConfigReverting) {
        self.reverter = reverter
    }

    /// Reverts every agent that Quotio currently has configured for its proxy.
    ///
    /// Agents are handled independently: a thrown error or an unsuccessful result
    /// for one agent is recorded and the loop continues, so a single broken config
    /// can never block the rest of the revert (or app termination).
    func restoreConfiguredAgents(agents: [CLIAgent] = CLIAgent.allCases) async -> AgentQuitRestoreOutcome {
        var outcome = AgentQuitRestoreOutcome()

        for agent in agents {
            guard await reverter.isConfiguredForQuotioProxy(agent: agent) else {
                outcome.skipped.append(agent)
                continue
            }

            do {
                let result = try await reverter.revertToDefault(agent: agent)
                if result.success {
                    outcome.reverted.append(agent)
                } else {
                    outcome.failures.append(
                        AgentQuitRestoreFailure(agent: agent, message: result.error ?? "unknown error")
                    )
                }
            } catch {
                outcome.failures.append(
                    AgentQuitRestoreFailure(agent: agent, message: error.localizedDescription)
                )
            }
        }

        return outcome
    }
}
