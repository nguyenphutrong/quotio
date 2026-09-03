import Foundation
import QuotioDomain

public struct ProxyManagementConnection: Equatable, Sendable {
    public let baseURL: String
    public let authKey: String

    public init(baseURL: String, authKey: String) {
        self.baseURL = baseURL
        self.authKey = authKey
    }
}

public protocol ProxyManagementAPI: Sendable {
    func invalidate() async
    func fetchAuthFiles() async throws -> [ManagedAuthFile]
    func fetchAuthFileModels(name: String) async throws -> [ManagedModelInfo]
    func apiCall(_ request: ProxyAPICall) async throws -> ProxyAPICallResult
    func deleteAuthFile(name: String) async throws
    func uploadAuthFile(name: String, content: Data) async throws
    func downloadAuthFile(name: String) async throws -> Data
    func deleteAllAuthFiles() async throws
    func setAuthFileDisabled(name: String, disabled: Bool) async throws
    func fetchUsageStats() async throws -> ProxyUsageStats
    func startOAuth(for provider: ProxyManagementOAuthProvider) async throws -> ProxyOAuthStart
    func pollOAuthStatus(state: String) async throws -> ProxyOAuthStatus
    func fetchConfig() async throws -> ProxyManagementConfiguration
    func setDebug(_ enabled: Bool) async throws
    func routingStrategy() async throws -> String
    func setRoutingStrategy(_ strategy: String) async throws
    func setQuotaExceededSwitchProject(_ enabled: Bool) async throws
    func setQuotaExceededSwitchPreviewModel(_ enabled: Bool) async throws
    func setRequestRetry(_ count: Int) async throws
    func setMaxRetryInterval(_ seconds: Int) async throws
    func setProxyURL(_ url: String) async throws
    func deleteProxyURL() async throws
    func setLoggingToFile(_ enabled: Bool) async throws
    func setRequestLog(_ enabled: Bool) async throws
    func uploadVertexServiceAccount(data: Data) async throws
    func fetchAPIKeys() async throws -> [String]
    func addAPIKey(_ key: String) async throws
    func replaceAPIKeys(_ keys: [String]) async throws
    func updateAPIKey(old: String, new: String) async throws
    func deleteAPIKey(value: String) async throws
    func deleteAPIKey(at index: Int) async throws
    func latestVersion() async throws -> ProxyLatestVersion
    func isResponding() async -> Bool
}

public protocol ProxyManagementAPIFactory: Sendable {
    func makeManagementAPI(connection: ProxyManagementConnection) -> any ProxyManagementAPI
}

public protocol ManagedAuthFileStateRepository: Sendable {
    func disabledAuthFileNames() -> Set<String>
    func saveDisabledAuthFileNames(_ names: Set<String>)
    func recordAuthFilesChanged(at date: Date)
}

public enum ProxyManagementFailure: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case connectionError(String)
}
