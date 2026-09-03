import Foundation
import QuotioApplication
import QuotioDomain

public struct LiveProxyManagementAPIFactory: ProxyManagementAPIFactory {
    public init() {}

    public func makeManagementAPI(connection: ProxyManagementConnection) -> any ProxyManagementAPI {
        URLSessionProxyManagementAPI(connection: connection)
    }
}

public final class UserDefaultsManagedAuthFileStateRepository: ManagedAuthFileStateRepository,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let disabledAuthFilesKey = "persisted.disabledAuthFiles"
    private let authFilesChangedKey = "quotio.authFiles.lastChanged"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func disabledAuthFileNames() -> Set<String> {
        Set(defaults.stringArray(forKey: disabledAuthFilesKey) ?? [])
    }

    public func saveDisabledAuthFileNames(_ names: Set<String>) {
        defaults.set(Array(names), forKey: disabledAuthFilesKey)
    }

    public func recordAuthFilesChanged(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: authFilesChangedKey)
    }
}

public actor URLSessionProxyManagementAPI: ProxyManagementAPI {
    public struct TimeoutConfiguration: Equatable, Sendable {
        public let requestTimeout: TimeInterval
        public let resourceTimeout: TimeInterval
        public let maxRetries: Int

        public init(requestTimeout: TimeInterval, resourceTimeout: TimeInterval, maxRetries: Int) {
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
            self.maxRetries = maxRetries
        }

        public static let local = TimeoutConfiguration(
            requestTimeout: 15,
            resourceTimeout: 45,
            maxRetries: 4
        )
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let connection: ProxyManagementConnection
    private let session: URLSession
    private let timeoutConfiguration: TimeoutConfiguration
    private let sleep: Sleep

    public init(
        connection: ProxyManagementConnection,
        timeoutConfiguration: TimeoutConfiguration = .local
    ) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutConfiguration.requestTimeout
        configuration.timeoutIntervalForResource = timeoutConfiguration.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.connection = connection
        self.timeoutConfiguration = timeoutConfiguration
        self.session = URLSession(configuration: configuration)
        self.sleep = { try await Task.sleep(for: $0) }
    }

    init(
        connection: ProxyManagementConnection,
        session: URLSession,
        timeoutConfiguration: TimeoutConfiguration = .local,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.connection = connection
        self.session = session
        self.timeoutConfiguration = timeoutConfiguration
        self.sleep = sleep
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }

    public func fetchAuthFiles() async throws -> [ManagedAuthFile] {
        try await decode(AuthFilesResponse.self, path: "/auth-files").files
    }

    public func fetchAuthFileModels(name: String) async throws -> [ManagedModelInfo] {
        let path = try namedPath("/auth-files/models", name: name)
        return try await decode(AuthFileModelsResponse.self, path: path).models
    }

    public func apiCall(_ request: ProxyAPICall) async throws -> ProxyAPICallResult {
        try await decode(
            ProxyAPICallResult.self,
            path: "/api-call",
            method: "POST",
            body: try JSONEncoder().encode(request)
        )
    }

    public func deleteAuthFile(name: String) async throws {
        _ = try await send(path: namedPath("/auth-files", name: name), method: "DELETE")
    }

    public func uploadAuthFile(name: String, content: Data) async throws {
        _ = try await send(path: namedPath("/auth-files", name: name), method: "POST", body: content)
    }

    public func downloadAuthFile(name: String) async throws -> Data {
        try await send(path: namedPath("/auth-files/download", name: name))
    }

    public func deleteAllAuthFiles() async throws {
        _ = try await send(path: "/auth-files?all=true", method: "DELETE")
    }

    public func setAuthFileDisabled(name: String, disabled: Bool) async throws {
        _ = try await send(
            path: "/auth-files/status",
            method: "PATCH",
            body: try JSONEncoder().encode(AuthFileStatusRequest(name: name, disabled: disabled))
        )
    }

    public func fetchUsageStats() async throws -> ProxyUsageStats {
        try await decode(ProxyUsageStats.self, path: "/usage")
    }

    public func startOAuth(for provider: ProxyManagementOAuthProvider) async throws -> ProxyOAuthStart {
        let endpoint: String = switch provider {
        case .claude: "/anthropic-auth-url?is_webui=true"
        case .codex: "/codex-auth-url?is_webui=true"
        case .qwen: "/qwen-auth-url"
        case .iflow: "/iflow-auth-url?is_webui=true"
        case .antigravity: "/antigravity-auth-url?is_webui=true"
        }
        return try await decode(ProxyOAuthStart.self, path: endpoint)
    }

    public func pollOAuthStatus(state: String) async throws -> ProxyOAuthStatus {
        try await decode(ProxyOAuthStatus.self, path: "/get-auth-status?state=\(state)")
    }

    public func fetchConfig() async throws -> ProxyManagementConfiguration {
        try await decode(ProxyManagementConfiguration.self, path: "/config")
    }

    public func setDebug(_ enabled: Bool) async throws { try await putValue(enabled, path: "/debug") }

    public func routingStrategy() async throws -> String {
        do {
            return try await decode(RoutingStrategyResponse.self, path: "/routing/strategy").strategy
        } catch ProxyManagementFailure.httpError(404) {
            return try await decode(RoutingStrategyResponse.self, path: "/routing").strategy
        }
    }

    public func setRoutingStrategy(_ strategy: String) async throws {
        do {
            try await putValue(strategy, path: "/routing/strategy")
        } catch ProxyManagementFailure.httpError(404) {
            _ = try await send(
                path: "/routing",
                method: "PUT",
                body: try JSONEncoder().encode(["strategy": strategy])
            )
        }
    }

    public func setQuotaExceededSwitchProject(_ enabled: Bool) async throws {
        try await patchValue(enabled, path: "/quota-exceeded/switch-project")
    }

    public func setQuotaExceededSwitchPreviewModel(_ enabled: Bool) async throws {
        try await patchValue(enabled, path: "/quota-exceeded/switch-preview-model")
    }

    public func setRequestRetry(_ count: Int) async throws { try await putValue(count, path: "/request-retry") }
    public func setMaxRetryInterval(_ seconds: Int) async throws { try await putValue(seconds, path: "/max-retry-interval") }
    public func setProxyURL(_ url: String) async throws { try await putValue(url, path: "/proxy-url") }

    public func deleteProxyURL() async throws {
        _ = try await send(path: "/proxy-url", method: "DELETE")
    }

    public func setLoggingToFile(_ enabled: Bool) async throws { try await putValue(enabled, path: "/logging-to-file") }
    public func setRequestLog(_ enabled: Bool) async throws { try await putValue(enabled, path: "/request-log") }

    public func uploadVertexServiceAccount(data: Data) async throws {
        _ = try await send(path: "/vertex/import", method: "POST", body: data)
    }

    public func fetchAPIKeys() async throws -> [String] {
        try await decode(APIKeysResponse.self, path: "/api-keys").apiKeys
    }

    public func addAPIKey(_ key: String) async throws {
        var keys = try await fetchAPIKeys()
        keys.append(key)
        try await replaceAPIKeys(keys)
    }

    public func replaceAPIKeys(_ keys: [String]) async throws {
        _ = try await send(path: "/api-keys", method: "PUT", body: try JSONEncoder().encode(keys))
    }

    public func updateAPIKey(old: String, new: String) async throws {
        _ = try await send(
            path: "/api-keys",
            method: "PATCH",
            body: try JSONEncoder().encode(["old": old, "new": new])
        )
    }

    public func deleteAPIKey(value: String) async throws {
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        _ = try await send(path: "/api-keys?value=\(encoded)", method: "DELETE")
    }

    public func deleteAPIKey(at index: Int) async throws {
        _ = try await send(path: "/api-keys?index=\(index)", method: "DELETE")
    }

    public func latestVersion() async throws -> ProxyLatestVersion {
        try await decode(ProxyLatestVersion.self, path: "/latest-version")
    }

    public func isResponding() async -> Bool {
        (try? await send(path: "/debug")) != nil
    }

    private func putValue<Value: Encodable & Sendable>(_ value: Value, path: String) async throws {
        _ = try await send(path: path, method: "PUT", body: try JSONEncoder().encode(["value": value]))
    }

    private func patchValue<Value: Encodable & Sendable>(_ value: Value, path: String) async throws {
        _ = try await send(path: path, method: "PATCH", body: try JSONEncoder().encode(["value": value]))
    }

    private func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Value {
        try JSONDecoder().decode(type, from: await send(path: path, method: method, body: body))
    }

    private func send(path: String, method: String = "GET", body: Data? = nil, retry: Int = 0) async throws -> Data {
        guard let url = URL(string: connection.baseURL + path) else {
            throw ProxyManagementFailure.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(connection.authKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ProxyManagementFailure.invalidResponse
            }
            guard 200...299 ~= response.statusCode else {
                throw ProxyManagementFailure.httpError(response.statusCode)
            }
            return data
        } catch let error as URLError where retry < timeoutConfiguration.maxRetries && Self.isRetryable(error) {
            let seconds = min(pow(2, Double(retry)) * 0.5, 3)
            try? await sleep(.milliseconds(Int64(seconds * 1_000)))
            return try await send(path: path, method: method, body: body, retry: retry + 1)
        } catch let error as URLError {
            throw ProxyManagementFailure.connectionError(error.localizedDescription)
        }
    }

    private func namedPath(_ path: String, name: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ProxyManagementFailure.invalidURL
        }
        return path + "?name=" + encoded
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cannotConnectToHost
    }
}

private struct AuthFilesResponse: Decodable { let files: [ManagedAuthFile] }
private struct AuthFileModelsResponse: Decodable { let models: [ManagedModelInfo] }
private struct AuthFileStatusRequest: Encodable { let name: String; let disabled: Bool }

private struct APIKeysResponse: Decodable {
    let apiKeys: [String]
    enum CodingKeys: String, CodingKey { case apiKeys = "api-keys" }
}

private struct RoutingStrategyResponse: Decodable {
    let strategy: String

    private enum CodingKeys: String, CodingKey { case strategy, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let strategy = try container.decodeIfPresent(String.self, forKey: .strategy) {
            self.strategy = strategy
        } else {
            self.strategy = try container.decode(String.self, forKey: .value)
        }
    }
}
