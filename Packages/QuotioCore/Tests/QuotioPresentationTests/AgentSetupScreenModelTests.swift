import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class AgentSetupScreenModelTests: XCTestCase {
    func testStartConfigurationUsesInjectedEndpointContext() {
        let model = makeModel(
            adapters: [ScreenAgentRepository(agent: .ampCLI)],
            endpoint: AgentEndpointContext(baseURL: "https://tunnel.example", apiKey: "proxy-key")
        )

        model.startConfiguration(for: .ampCLI)

        XCTAssertEqual(model.selectedAgent, .ampCLI)
        XCTAssertEqual(model.currentConfiguration?.proxyURL, "https://tunnel.example/v1")
        XCTAssertEqual(model.currentConfiguration?.apiKey, "proxy-key")
    }

    func testCatalogAndPickerWithoutEndpointDoNotInventModels() async {
        let model = makeModel(
            adapters: [ScreenAgentRepository(agent: .claudeCode)],
            endpoint: nil
        )

        do {
            _ = try await model.fetchModelCatalog()
            XCTFail("Expected unavailable proxy error")
        } catch {
            XCTAssertEqual(error as? ModelCatalogError, .proxyUnavailable)
        }
        let loadedModels = await model.loadModels()
        XCTAssertFalse(loadedModels)
        XCTAssertTrue(model.availableModels.isEmpty)
    }

    func testChangingSelectionRejectsLateConfigurationFromCancelledTask() async throws {
        let gate = InspectionGate()
        let claudeSaved = SavedAgentConfiguration(
            baseURL: "http://claude.example",
            apiKey: nil,
            modelSlots: [.opus: "stale-claude-model"],
            isProxyConfigured: true,
            backupFiles: []
        )
        let codexSaved = SavedAgentConfiguration(
            baseURL: "http://codex.example",
            apiKey: nil,
            modelSlots: [.sonnet: "current-codex-model"],
            isProxyConfigured: true,
            backupFiles: [],
            reasoningEffort: .ultra
        )
        let model = makeModel(
            adapters: [
                ScreenAgentRepository(agent: .claudeCode, saved: claudeSaved, inspectionGate: gate),
                ScreenAgentRepository(agent: .codexCLI, saved: codexSaved),
            ],
            endpoint: AgentEndpointContext(baseURL: "http://127.0.0.1:8317", apiKey: "key")
        )

        model.startConfiguration(for: .claudeCode)
        let claudeInspectionStarted = await waitUntil { await gate.hasWaiter() }
        XCTAssertTrue(claudeInspectionStarted)
        model.startConfiguration(for: .codexCLI)
        let codexInspectionFinished = await waitUntil {
            model.savedConfig?.baseURL == "http://codex.example"
        }
        XCTAssertTrue(codexInspectionFinished)
        await gate.resume()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.selectedAgent, .codexCLI)
        XCTAssertEqual(model.savedConfig?.baseURL, "http://codex.example")
        XCTAssertEqual(model.currentConfiguration?.modelSlots[.sonnet], "current-codex-model")
        XCTAssertEqual(model.currentConfiguration?.codexReasoningEffort, .ultra)
        XCTAssertNotEqual(model.currentConfiguration?.modelSlots[.opus], "stale-claude-model")
    }

    func testRefreshPublishesDetectedShellPathAndStatuses() async {
        let detector = ScreenAgentDetector(statuses: [
            AgentStatus(
                agent: .openCode,
                installed: true,
                configured: false,
                binaryPath: "/usr/local/bin/opencode",
                version: "1.0",
                lastConfigured: nil
            ),
        ])
        let service = AgentConfigurationService(
            adapters: [ScreenAgentRepository(agent: .openCode)],
            detector: detector,
            shellProfiles: ScreenShellProfiles(),
            modelCatalog: ScreenModelCatalog()
        )
        let model = AgentSetupScreenModel(service: service, endpointContext: { nil })

        await model.refreshAgentStatuses(forceRefresh: true)

        XCTAssertEqual(model.agentStatuses.map(\.agent), [.openCode])
        XCTAssertEqual(model.detectedShell, .fish)
        XCTAssertEqual(model.detectedShellProfilePath, "/tmp/config.fish")
    }

    private func makeModel(
        adapters: [any AgentConfigurationRepository],
        endpoint: AgentEndpointContext?
    ) -> AgentSetupScreenModel {
        AgentSetupScreenModel(
            service: AgentConfigurationService(
                adapters: adapters,
                detector: ScreenAgentDetector(),
                shellProfiles: ScreenShellProfiles(),
                modelCatalog: ScreenModelCatalog()
            ),
            endpointContext: { endpoint }
        )
    }

    private func waitUntil(
        attempts: Int = 500,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private actor InspectionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasWaiter() -> Bool { continuation != nil }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ScreenAgentRepository: AgentConfigurationRepository {
    nonisolated let agent: CLIAgent
    private let saved: SavedAgentConfiguration?
    private let inspectionGate: InspectionGate?

    init(
        agent: CLIAgent,
        saved: SavedAgentConfiguration? = nil,
        inspectionGate: InspectionGate? = nil
    ) {
        self.agent = agent
        self.saved = saved
        self.inspectionGate = inspectionGate
    }

    func inspect() async -> SavedAgentConfiguration? {
        await inspectionGate?.wait()
        return saved
    }

    func preview(_ request: AgentConfigurationRequest) -> AgentConfigResult {
        .success(type: agent.configType, mode: request.mode, instructions: .ampMergeAndSaveFiles)
    }

    func apply(_ request: AgentConfigurationRequest) -> AgentConfigResult {
        .success(type: agent.configType, mode: request.mode, instructions: .ampConfigured)
    }

    func reset(mode: ConfigurationMode) -> AgentConfigResult {
        .success(type: agent.configType, mode: mode, instructions: .ampProxyRemoved)
    }

    func listBackups() -> [AgentBackupFile] { [] }
    func restore(_ backup: AgentBackupFile) {}
}

private actor ScreenAgentDetector: AgentDetecting {
    private let statuses: [AgentStatus]

    init(statuses: [AgentStatus] = []) {
        self.statuses = statuses
    }

    func detectAll(forceRefresh: Bool) -> [AgentStatus] { statuses }

    func detect(_ agent: CLIAgent) -> AgentStatus {
        statuses.first { $0.agent == agent } ?? AgentStatus(
            agent: agent,
            installed: false,
            configured: false,
            binaryPath: nil,
            version: nil,
            lastConfigured: nil
        )
    }

    func markConfigured(_ agent: CLIAgent) {}
    func clearConfigured(_ agent: CLIAgent) {}
}

private actor ScreenShellProfiles: ShellProfileRepository {
    func detect() -> ShellProfile { ShellProfile(shell: .fish, path: "/tmp/config.fish") }
    func add(configuration: String, for agent: CLIAgent, to profile: ShellProfile) {}
    func removeConfiguration(for agent: CLIAgent, from profile: ShellProfile) {}
}

private actor ScreenModelCatalog: AgentModelCatalogRepository {
    func fetchCatalog(configuration: AgentConfiguration) -> [ModelCatalogEntry] { [] }
    func fetchAvailableModels(configuration: AgentConfiguration) -> [AvailableModel] { [] }

    func testConnection(
        agent: CLIAgent,
        configuration: AgentConfiguration
    ) -> ConnectionTestResult {
        ConnectionTestResult(success: true, message: .connected, latencyMs: nil, modelResponded: nil)
    }
}
