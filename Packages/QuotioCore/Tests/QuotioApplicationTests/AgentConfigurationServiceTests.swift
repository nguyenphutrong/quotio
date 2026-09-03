import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class AgentConfigurationServiceTests: XCTestCase {
    func testApplyRoutesThroughAgentAdapterShellProfileAndDetector() async throws {
        let adapter = StubAgentConfigurationRepository(agent: .ampCLI)
        let detector = StubAgentDetector()
        let shell = StubShellProfiles()
        let service = AgentConfigurationService(
            adapters: [adapter],
            detector: detector,
            shellProfiles: shell,
            modelCatalog: StubAgentModelCatalog()
        )
        let profile = ShellProfile(shell: .zsh, path: "/tmp/.zshrc")

        let result = try await service.apply(
            request(agent: .ampCLI, mode: .automatic, storageOption: .both),
            shellProfile: profile
        )

        XCTAssertTrue(result.success)
        let operations = await adapter.operations()
        let shellAdditions = await shell.added()
        let markedAgents = await detector.marked()
        XCTAssertEqual(operations, ["apply"])
        XCTAssertEqual(shellAdditions, ["amp:/tmp/.zshrc"])
        XCTAssertEqual(markedAgents, [.ampCLI])
    }

    func testDefaultSetupUsesResetAndClearsConfiguredStatus() async throws {
        let adapter = StubAgentConfigurationRepository(agent: .claudeCode)
        let detector = StubAgentDetector()
        let service = AgentConfigurationService(
            adapters: [adapter],
            detector: detector,
            shellProfiles: StubShellProfiles(),
            modelCatalog: StubAgentModelCatalog()
        )
        var configuration = request(agent: .claudeCode, mode: .automatic).configuration
        configuration.setupMode = .defaultSetup

        _ = try await service.apply(
            AgentConfigurationRequest(configuration: configuration, mode: .automatic),
            shellProfile: ShellProfile(shell: .bash, path: "/tmp/.bashrc")
        )

        let operations = await adapter.operations()
        let clearedAgents = await detector.cleared()
        XCTAssertEqual(operations, ["reset:automatic"])
        XCTAssertEqual(clearedAgents, [.claudeCode])
    }

    func testPreviewRestoreAndBackupUseTheRegisteredAgentContract() async throws {
        let adapter = StubAgentConfigurationRepository(agent: .codexCLI)
        let service = AgentConfigurationService(
            adapters: [adapter],
            detector: StubAgentDetector(),
            shellProfiles: StubShellProfiles(),
            modelCatalog: StubAgentModelCatalog()
        )
        let backup = AgentBackupFile(
            path: "/tmp/config.toml.backup.1",
            timestamp: Date(timeIntervalSince1970: 1),
            agent: .codexCLI
        )

        _ = try await service.generatePreview(request(agent: .codexCLI, mode: .manual))
        _ = try await service.listBackups(for: .codexCLI)
        try await service.restore(backup)

        let operations = await adapter.operations()
        XCTAssertEqual(operations, ["preview", "backups", "restore"])
    }

    func testMissingAdapterFailsWithoutFallingThroughToAnotherAgent() async {
        let service = AgentConfigurationService(
            adapters: [StubAgentConfigurationRepository(agent: .codexCLI)],
            detector: StubAgentDetector(),
            shellProfiles: StubShellProfiles(),
            modelCatalog: StubAgentModelCatalog()
        )

        do {
            _ = try await service.inspect(.ampCLI)
            XCTFail("Expected missing adapter error")
        } catch {
            XCTAssertEqual(error as? AgentConfigurationServiceError, .missingAdapter(.ampCLI))
        }
    }

    private func request(
        agent: CLIAgent,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly
    ) -> AgentConfigurationRequest {
        AgentConfigurationRequest(
            configuration: AgentConfiguration(
                agent: agent,
                proxyURL: "http://127.0.0.1:8317/v1",
                apiKey: "key"
            ),
            mode: mode,
            storageOption: storageOption
        )
    }
}

private actor StubAgentConfigurationRepository: AgentConfigurationRepository {
    nonisolated let agent: CLIAgent
    private var recorded: [String] = []

    init(agent: CLIAgent) {
        self.agent = agent
    }

    func inspect() -> SavedAgentConfiguration? {
        recorded.append("inspect")
        return nil
    }

    func preview(_ request: AgentConfigurationRequest) -> AgentConfigResult {
        recorded.append("preview")
        return result(mode: request.mode)
    }

    func apply(_ request: AgentConfigurationRequest) -> AgentConfigResult {
        recorded.append("apply")
        return .success(
            type: agent.configType,
            mode: request.mode,
            shellConfig: "export TEST=1",
            instructions: "Applied"
        )
    }

    func reset(mode: ConfigurationMode) -> AgentConfigResult {
        recorded.append("reset:\(mode.rawValue)")
        return result(mode: mode)
    }

    func listBackups() -> [AgentBackupFile] {
        recorded.append("backups")
        return []
    }

    func restore(_ backup: AgentBackupFile) {
        recorded.append("restore")
    }

    func operations() -> [String] { recorded }

    private func result(mode: ConfigurationMode) -> AgentConfigResult {
        .success(type: agent.configType, mode: mode, instructions: "Success")
    }
}

private actor StubAgentDetector: AgentDetecting {
    private var markedAgents: [CLIAgent] = []
    private var clearedAgents: [CLIAgent] = []

    func detectAll(forceRefresh: Bool) -> [AgentStatus] { [] }

    func detect(_ agent: CLIAgent) -> AgentStatus {
        AgentStatus(
            agent: agent,
            installed: true,
            configured: false,
            binaryPath: nil,
            version: nil,
            lastConfigured: nil
        )
    }

    func markConfigured(_ agent: CLIAgent) { markedAgents.append(agent) }
    func clearConfigured(_ agent: CLIAgent) { clearedAgents.append(agent) }
    func marked() -> [CLIAgent] { markedAgents }
    func cleared() -> [CLIAgent] { clearedAgents }
}

private actor StubShellProfiles: ShellProfileRepository {
    private var additions: [String] = []

    func detect() -> ShellProfile { ShellProfile(shell: .zsh, path: "/tmp/.zshrc") }

    func add(configuration: String, for agent: CLIAgent, to profile: ShellProfile) {
        additions.append("\(agent.rawValue):\(profile.path)")
    }

    func removeConfiguration(for agent: CLIAgent, from profile: ShellProfile) {}
    func added() -> [String] { additions }
}

private actor StubAgentModelCatalog: AgentModelCatalogRepository {
    func fetchCatalog(configuration: AgentConfiguration) -> [ModelCatalogEntry] { [] }
    func fetchAvailableModels(configuration: AgentConfiguration) -> [AvailableModel] { [] }

    func testConnection(
        agent: CLIAgent,
        configuration: AgentConfiguration
    ) -> ConnectionTestResult {
        ConnectionTestResult(success: true, message: "Connected", latencyMs: 1, modelResponded: nil)
    }
}
