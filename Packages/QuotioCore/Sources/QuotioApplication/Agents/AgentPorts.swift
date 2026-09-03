import Foundation
import QuotioDomain

public protocol AgentConfigurationRepository: Sendable {
    var agent: CLIAgent { get }

    func inspect() async -> SavedAgentConfiguration?
    func preview(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult
    func apply(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult
    func reset(mode: ConfigurationMode) async throws -> AgentConfigResult
    func listBackups() async -> [AgentBackupFile]
    func restore(_ backup: AgentBackupFile) async throws
}

public protocol AgentDetecting: Sendable {
    func detectAll(forceRefresh: Bool) async -> [AgentStatus]
    func detect(_ agent: CLIAgent) async -> AgentStatus
    func markConfigured(_ agent: CLIAgent) async
    func clearConfigured(_ agent: CLIAgent) async
}

public protocol CLIToolInstallationProbing: Sendable {
    func isInstalled(binaryName: String) async -> Bool
}

public struct ShellProfile: Equatable, Sendable {
    public let shell: ShellType
    public let path: String

    public init(shell: ShellType, path: String) {
        self.shell = shell
        self.path = path
    }
}

public protocol ShellProfileRepository: Sendable {
    func detect() async -> ShellProfile
    func add(configuration: String, for agent: CLIAgent, to profile: ShellProfile) async throws
    func removeConfiguration(for agent: CLIAgent, from profile: ShellProfile) async throws
}

public protocol AgentModelCatalogRepository: Sendable {
    func fetchCatalog(configuration: AgentConfiguration) async throws -> [ModelCatalogEntry]
    func fetchAvailableModels(configuration: AgentConfiguration) async throws -> [AvailableModel]
    func testConnection(agent: CLIAgent, configuration: AgentConfiguration) async -> ConnectionTestResult
}

public enum AgentConfigurationServiceError: LocalizedError, Equatable, Sendable {
    case missingAdapter(CLIAgent)
    case adapterMismatch(expected: CLIAgent, actual: CLIAgent)

    public var errorDescription: String? {
        switch self {
        case .missingAdapter(let agent):
            return "No configuration adapter is registered for \(agent.rawValue)."
        case .adapterMismatch(let expected, let actual):
            return "The \(expected.rawValue) adapter cannot configure \(actual.rawValue)."
        }
    }
}

public typealias AgentTextLocalizer = @Sendable (_ key: String) -> String
