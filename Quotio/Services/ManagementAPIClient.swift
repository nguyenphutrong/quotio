//
//  ManagementAPIClient.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation

actor ManagementAPIClient {
    private let baseURL: String
    private let authKey: String
    private let session: URLSession
    private let sessionDelegate: SessionDelegate
    private let clientId: String
    
    /// Whether this client is connected to a remote server (vs localhost)
    let isRemote: Bool
    
    /// Timeout configuration used for this client
    let timeoutConfig: TimeoutConfig
    
    // MARK: - Timeout Configuration
    
    /// Timeout settings for API requests
    struct TimeoutConfig: Sendable {
        let requestTimeout: TimeInterval
        let resourceTimeout: TimeInterval
        let maxRetries: Int

        /// Default timeouts for local connections (faster, more reliable)
        /// Increased maxRetries to handle proxy restart scenarios (graceful shutdown can take 1-2s)
        static let local = TimeoutConfig(
            requestTimeout: 15,
            resourceTimeout: 45,
            maxRetries: 4  // Was: 1. Now: 4 retries with exponential backoff = ~6.5s total wait
        )

        /// Timeouts for remote connections (slower, needs more patience)
        static let remote = TimeoutConfig(
            requestTimeout: 30,
            resourceTimeout: 90,
            maxRetries: 5  // Was: 2. Remote connections may need more retries
        )
        
        /// Custom timeout configuration
        static func custom(requestTimeout: TimeInterval, resourceTimeout: TimeInterval, maxRetries: Int = 1) -> TimeoutConfig {
            TimeoutConfig(requestTimeout: requestTimeout, resourceTimeout: resourceTimeout, maxRetries: maxRetries)
        }
    }
    
    // MARK: - Diagnostic Logging
    
    static let enableDiagnosticLogging = false
    nonisolated(unsafe) private static var activeRequests: Int = 0
    private static let requestLock = NSLock()
    
    private static func log(_ message: String) {
        guard enableDiagnosticLogging else { return }
        Log.api("\(message)")
    }
    
    private static func incrementActiveRequests() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        activeRequests += 1
        return activeRequests
    }
    
    private static func decrementActiveRequests() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        activeRequests -= 1
        return activeRequests
    }
    
    // MARK: - Initialization
    
    /// Initialize for local connection (localhost)
    init(baseURL: String, authKey: String) {
        self.baseURL = Self.normalizeManagementBaseURL(baseURL)
        self.authKey = authKey
        self.clientId = String(UUID().uuidString.prefix(6))
        self.isRemote = false
        self.timeoutConfig = .local
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutConfig.requestTimeout
        config.timeoutIntervalForResource = timeoutConfig.resourceTimeout
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        self.sessionDelegate = SessionDelegate(clientId: clientId)
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        
        Self.log("[\(clientId)] Local client created, baseURL=\(self.baseURL), timeout=\(Int(timeoutConfig.requestTimeout))/\(Int(timeoutConfig.resourceTimeout))s")
    }
    
    /// Initialize for remote connection with custom timeout
    /// - Warning: Setting `verifySSL: false` disables certificate validation, making the connection
    ///   vulnerable to man-in-the-middle attacks. Only use for self-signed certificates in trusted networks.
    init(baseURL: String, authKey: String, timeoutConfig: TimeoutConfig, verifySSL: Bool = true) {
        self.baseURL = Self.normalizeManagementBaseURL(baseURL)
        self.authKey = authKey
        self.clientId = String(UUID().uuidString.prefix(6))
        self.isRemote = true
        self.timeoutConfig = timeoutConfig
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutConfig.requestTimeout
        config.timeoutIntervalForResource = timeoutConfig.resourceTimeout
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        self.sessionDelegate = SessionDelegate(clientId: clientId, verifySSL: verifySSL)
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        
        Self.log("[\(clientId)] Remote client created, baseURL=\(self.baseURL), timeout=\(Int(timeoutConfig.requestTimeout))/\(Int(timeoutConfig.resourceTimeout))s, verifySSL=\(verifySSL)")
        
        if !verifySSL {
            Log.warning("SSL verification disabled for \(baseURL). Connection is vulnerable to MITM attacks.")
        }
    }
    
    /// Convenience initializer for remote connection with RemoteConnectionConfig
    init(config: RemoteConnectionConfig, managementKey: String) {
        let timeout = TimeoutConfig.custom(
            requestTimeout: TimeInterval(config.timeoutSeconds),
            resourceTimeout: TimeInterval(config.timeoutSeconds * 3),
            maxRetries: 2
        )
        self.init(
            baseURL: config.managementBaseURL,
            authKey: managementKey,
            timeoutConfig: timeout,
            verifySSL: config.verifySSL
        )
    }
    
    func invalidate() {
        Self.log("[\(clientId)] Session invalidating...")
        session.invalidateAndCancel()
    }
    
    private func makeRequest(_ endpoint: String, method: String = "GET", body: Data? = nil, retryCount: Int = 0) async throws -> Data {
        let (data, _) = try await makeDataRequest(endpoint, method: method, body: body, retryCount: retryCount)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8 response>"
            throw APIError.decodingError("Invalid JSON for \(type): \(preview)")
        }
    }

    private func makeDataRequest(_ endpoint: String, method: String = "GET", body: Data? = nil, retryCount: Int = 0) async throws -> (Data, HTTPURLResponse) {
        let requestId = String(UUID().uuidString.prefix(6))
        let activeCount = Self.incrementActiveRequests()
        let startTime = Date()
        
        Self.log("[\(clientId)][\(requestId)] START \(method) \(endpoint) (active=\(activeCount), retry=\(retryCount))")
        
        defer {
            let endCount = Self.decrementActiveRequests()
            let duration = Date().timeIntervalSince(startTime)
            Self.log("[\(clientId)][\(requestId)] END \(method) \(endpoint) duration=\(String(format: "%.3f", duration))s (active=\(endCount))")
        }
        
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // Force new connection to avoid stale connection issues after idle periods
        request.addValue("close", forHTTPHeaderField: "Connection")
        
        if let body = body {
            request.httpBody = body
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard 200...299 ~= httpResponse.statusCode else {
                Self.log("[\(clientId)][\(requestId)] HTTP ERROR \(httpResponse.statusCode)")
                throw APIError.httpError(httpResponse.statusCode)
            }
            
            return (data, httpResponse)
        } catch let error as URLError {
            Self.log("[\(clientId)][\(requestId)] URL ERROR: \(error.code.rawValue) - \(error.localizedDescription)")
            
            // Retry on timeout or connection errors (handles proxy restart scenarios)
            // Exponential backoff: 0.5s, 1s, 2s, 3s (total ~6.5s wait for proxy restart)
            if retryCount < timeoutConfig.maxRetries && (error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cannotConnectToHost || error.code == .cannotFindHost) {
                let backoffSeconds = min(pow(2.0, Double(retryCount)) * 0.5, 3.0)  // Cap at 3 seconds
                let backoffStr = String(format: "%.1f", backoffSeconds)
                Self.log("[\(clientId)][\(requestId)] RETRYING after \(backoffStr)s (attempt \(retryCount + 1)/\(timeoutConfig.maxRetries))...")
                
                // Exponential backoff delay
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                return try await makeDataRequest(endpoint, method: method, body: body, retryCount: retryCount + 1)
            }
            throw APIError.urlError(error)
        } catch {
            Self.log("[\(clientId)][\(requestId)] UNEXPECTED ERROR: \(error.localizedDescription)")
            throw error
        }
    }

    nonisolated static func normalizeManagementBaseURL(_ rawURL: String) -> String {
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }

        if url.hasSuffix("/v0/management") {
            return url
        }
        if url.hasSuffix("/v0") {
            return url + "/management"
        }
        if let range = url.range(of: "/v0/management/") {
            return String(url[..<range.upperBound]).dropLast().description
        }
        return url + "/v0/management"
    }
    
    func fetchAuthFiles() async throws -> [AuthFile] {
        let data = try await makeRequest("/auth-files")
        let response = try decode(AuthFilesResponse.self, from: data)
        return response.files
    }
    
    func fetchAuthFileModels(name: String) async throws -> [AuthFileModelInfo] {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let data = try await makeRequest("/auth-files/models?name=\(encoded)")
        let response = try decode(AuthFileModelsResponse.self, from: data)
        return response.models
    }
    
    func apiCall(_ request: APICallRequest) async throws -> APICallResponse {
        let body = try JSONEncoder().encode(request)
        let data = try await makeRequest("/api-call", method: "POST", body: body)
        return try decode(APICallResponse.self, from: data)
    }
    
    func deleteAuthFile(name: String) async throws {
        _ = try await makeRequest("/auth-files?name=\(name)", method: "DELETE")
    }
    
    func deleteAllAuthFiles() async throws {
        _ = try await makeRequest("/auth-files?all=true", method: "DELETE")
    }

    func setAuthFileDisabled(name: String, disabled: Bool) async throws {
        struct Request: Encodable {
            let name: String
            let disabled: Bool
        }
        let body = try JSONEncoder().encode(Request(name: name, disabled: disabled))
        _ = try await makeRequest("/auth-files/status", method: "PATCH", body: body)
    }
    
    func fetchUsageStats() async throws -> UsageStats {
        let data = try await makeRequest("/usage")
        return try decode(UsageStats.self, from: data)
    }

    func fetchQuota() async throws -> ManagementQuotaView {
        let data = try await makeRequest("/quota")
        return try decode(ManagementQuotaView.self, from: data)
    }

    func refreshQuota(provider: AIProvider? = nil, authID: String? = nil) async throws -> ManagementQuotaView {
        let endpoint: String
        if let provider, let authID {
            endpoint = "/quota/refresh/\(provider.rawValue)/\(authID)"
        } else {
            endpoint = "/quota/refresh"
        }
        let data = try await makeRequest(endpoint, method: "POST")
        return try decode(ManagementQuotaView.self, from: data)
    }
    
    func getOAuthURL(for provider: AIProvider, projectId: String? = nil) async throws -> OAuthURLResponse {
        var endpoint = provider.oauthEndpoint
        var queryParams: [String] = []
        
        if let projectId = projectId, provider == .gemini {
            queryParams.append("project_id=\(projectId)")
        }
        
        let webUIProviders: [AIProvider] = [.antigravity, .claude, .codex, .gemini, .iflow, .kiro]
        if webUIProviders.contains(provider) {
            queryParams.append("is_webui=true")
        }
        
        if !queryParams.isEmpty {
            endpoint += "?" + queryParams.joined(separator: "&")
        }
        
        let data = try await makeRequest(endpoint)
        return try decode(OAuthURLResponse.self, from: data)
    }
    
    func pollOAuthStatus(state: String) async throws -> OAuthStatusResponse {
        let data = try await makeRequest("/get-auth-status?state=\(state)")
        return try decode(OAuthStatusResponse.self, from: data)
    }
    
    func fetchLogs(after: Int? = nil) async throws -> LogsResponse {
        var endpoint = "/logs"
        if let after = after {
            endpoint += "?after=\(after)"
        }
        let data = try await makeRequest(endpoint)
        return try decode(LogsResponse.self, from: data)
    }
    
    func clearLogs() async throws {
        _ = try await makeRequest("/logs", method: "DELETE")
    }
    
    func setDebug(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(["value": enabled])
        _ = try await makeRequest("/debug", method: "PUT", body: body)
    }
    
    func setRoutingStrategy(_ strategy: String) async throws {
        let body = try JSONEncoder().encode(["value": strategy])
        _ = try await makeRequest("/routing/strategy", method: "PUT", body: body)
    }
    
    /// Get routing strategy
    func getRoutingStrategy() async throws -> String {
        let data = try await makeRequest("/routing/strategy")
        let response = try decode(RoutingStrategyResponse.self, from: data)
        return response.strategy
    }
    
    func setQuotaExceededSwitchProject(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(["value": enabled])
        _ = try await makeRequest("/quota-exceeded/switch-project", method: "PATCH", body: body)
    }
    
    func setQuotaExceededSwitchPreviewModel(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(["value": enabled])
        _ = try await makeRequest("/quota-exceeded/switch-preview-model", method: "PATCH", body: body)
    }
    
    func setRequestRetry(_ count: Int) async throws {
        let body = try JSONEncoder().encode(["value": count])
        _ = try await makeRequest("/request-retry", method: "PUT", body: body)
    }
    
    // MARK: - Remote Configuration Getters
    
    /// Fetch the full configuration from the remote server
    func fetchConfig() async throws -> RemoteProxyConfig {
        let data = try await makeRequest("/config")
        return try decode(RemoteProxyConfig.self, from: data)
    }
    
    /// Get debug mode status
    func getDebug() async throws -> Bool {
        let data = try await makeRequest("/debug")
        let response = try decode(DebugResponse.self, from: data)
        return response.debug
    }
    
    /// Get proxy URL (upstream proxy)
    func getProxyURL() async throws -> String {
        let data = try await makeRequest("/proxy-url")
        let response = try decode(ProxyURLResponse.self, from: data)
        return response.proxyURL
    }
    
    /// Set proxy URL (upstream proxy)
    func setProxyURL(_ url: String) async throws {
        let body = try JSONEncoder().encode(["value": url])
        _ = try await makeRequest("/proxy-url", method: "PUT", body: body)
    }
    
    /// Delete/clear proxy URL
    func deleteProxyURL() async throws {
        _ = try await makeRequest("/proxy-url", method: "DELETE")
    }
    
    /// Get logging to file status
    func getLoggingToFile() async throws -> Bool {
        let data = try await makeRequest("/logging-to-file")
        let response = try decode(LoggingToFileResponse.self, from: data)
        return response.loggingToFile
    }
    
    /// Set logging to file
    func setLoggingToFile(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(["value": enabled])
        _ = try await makeRequest("/logging-to-file", method: "PUT", body: body)
    }
    
    /// Get request log status
    func getRequestLog() async throws -> Bool {
        let data = try await makeRequest("/request-log")
        let response = try decode(RequestLogResponse.self, from: data)
        return response.requestLog
    }
    
    /// Set request log
    func setRequestLog(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(["value": enabled])
        _ = try await makeRequest("/request-log", method: "PUT", body: body)
    }
    
    /// Get request retry count
    func getRequestRetry() async throws -> Int {
        let data = try await makeRequest("/request-retry")
        let response = try decode(RequestRetryResponse.self, from: data)
        return response.requestRetry
    }
    
    /// Get max retry interval
    func getMaxRetryInterval() async throws -> Int {
        let data = try await makeRequest("/max-retry-interval")
        let response = try decode(MaxRetryIntervalResponse.self, from: data)
        return response.maxRetryInterval
    }
    
    /// Set max retry interval
    func setMaxRetryInterval(_ seconds: Int) async throws {
        let body = try JSONEncoder().encode(["value": seconds])
        _ = try await makeRequest("/max-retry-interval", method: "PUT", body: body)
    }
    
    /// Get quota exceeded switch project status
    func getQuotaExceededSwitchProject() async throws -> Bool {
        let data = try await makeRequest("/quota-exceeded/switch-project")
        let response = try decode(SwitchProjectResponse.self, from: data)
        return response.switchProject
    }
    
    /// Get quota exceeded switch preview model status
    func getQuotaExceededSwitchPreviewModel() async throws -> Bool {
        let data = try await makeRequest("/quota-exceeded/switch-preview-model")
        let response = try decode(SwitchPreviewModelResponse.self, from: data)
        return response.switchPreviewModel
    }
    
    func uploadVertexServiceAccount(jsonPath: String) async throws {
        let url = URL(fileURLWithPath: jsonPath)
        let fileData = try Data(contentsOf: url)
        try await uploadVertexServiceAccount(data: fileData)
    }

    func uploadVertexServiceAccount(data: Data) async throws {
        _ = try await makeRequest("/vertex/import", method: "POST", body: data)
    }
    
    func fetchAPIKeys() async throws -> [String] {
        let data = try await makeRequest("/api-keys")
        let response = try decode(APIKeysResponse.self, from: data)
        return response.apiKeys
    }
    
    func addAPIKey(_ key: String) async throws {
        let currentKeys = try await fetchAPIKeys()
        var newKeys = currentKeys
        newKeys.append(key)
        try await replaceAPIKeys(newKeys)
    }
    
    func replaceAPIKeys(_ keys: [String]) async throws {
        let body = try JSONEncoder().encode(keys)
        _ = try await makeRequest("/api-keys", method: "PUT", body: body)
    }
    
    func updateAPIKey(old: String, new: String) async throws {
        let body = try JSONEncoder().encode(["old": old, "new": new])
        _ = try await makeRequest("/api-keys", method: "PATCH", body: body)
    }
    
    func deleteAPIKey(value: String) async throws {
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        _ = try await makeRequest("/api-keys?value=\(encodedValue)", method: "DELETE")
    }
    
    func deleteAPIKeyByIndex(_ index: Int) async throws {
        _ = try await makeRequest("/api-keys?index=\(index)", method: "DELETE")
    }
    
    // MARK: - Proxy Version & Health
    
    /// Fetch the latest proxy version available from the running proxy.
    /// The proxy fetches this from GitHub releases.
    func fetchLatestVersion() async throws -> LatestVersionResponse {
        let data = try await makeRequest("/latest-version")
        return try decode(LatestVersionResponse.self, from: data)
    }
    
    /// Check if proxy is responding by calling the debug endpoint.
    /// This is simpler than /health which may not exist.
    func checkProxyResponding() async -> Bool {
        do {
            _ = try await checkServer()
            return true
        } catch {
            return false
        }
    }

    func checkServer() async throws -> ManagementServerInfo {
        let (_, response) = try await makeDataRequest("/debug")
        let version = response.value(forHTTPHeaderField: "X-CPA-VERSION")
        return ManagementServerInfo(
            kind: version == nil ? .legacyCompatible : .cpaPlusPlus,
            version: version
        )
    }
}

nonisolated enum ManagementServerKind: String, Sendable {
    case cpaPlusPlus = "cpa-plusplus"
    case legacyCompatible = "legacy compatible"
}

nonisolated struct ManagementServerInfo: Sendable, Equatable {
    let kind: ManagementServerKind
    let version: String?
}

// MARK: - Latest Version Response

nonisolated struct LatestVersionResponse: Codable, Sendable {
    let latestVersion: String
    
    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest-version"
    }
}

// MARK: - Quota Response Types

nonisolated struct ManagementQuotaView: Codable, Sendable {
    let providers: [ManagementQuotaProvider]

    func providerQuotas() -> [AIProvider: [String: ProviderQuotaData]] {
        var result: [AIProvider: [String: ProviderQuotaData]] = [:]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        for providerView in providers {
            guard let provider = AIProvider(rawValue: providerView.provider) else { continue }
            for account in providerView.accounts {
                let key = account.accountKey.isEmpty ? account.credentialID : account.accountKey
                guard !key.isEmpty else { continue }
                let lastUpdated = formatter.date(from: account.lastUpdated ?? "")
                    ?? fallbackFormatter.date(from: account.lastUpdated ?? "")
                    ?? Date()
                let models = account.models.map { model in
                    ModelQuota(
                        name: model.name.isEmpty ? model.displayName : model.name,
                        percentage: model.remainingPercent ?? max(0, 100 - (model.usedPercent ?? 0)),
                        resetTime: model.resetTime ?? "",
                        used: model.used.map(Int.init),
                        limit: model.limit.map(Int.init),
                        remaining: model.remaining.map(Int.init),
                        tooltip: model.sourceDescription
                    )
                }
                result[provider, default: [:]][key] = ProviderQuotaData(
                    models: models,
                    lastUpdated: lastUpdated,
                    isForbidden: account.isForbidden,
                    planType: account.planDisplayName ?? account.planType
                )
            }
        }
        return result
    }
}

nonisolated struct ManagementQuotaProvider: Codable, Sendable {
    let provider: String
    let accounts: [ManagementQuotaAccount]
}

nonisolated struct ManagementQuotaAccount: Codable, Sendable {
    let credentialID: String
    let accountKey: String
    let planType: String?
    let planDisplayName: String?
    let isForbidden: Bool
    let lastUpdated: String?
    let models: [ManagementQuotaModel]

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case accountKey = "account_key"
        case planType = "plan_type"
        case planDisplayName = "plan_display_name"
        case isForbidden = "is_forbidden"
        case lastUpdated = "last_updated"
        case models
    }
}

nonisolated struct ManagementQuotaModel: Codable, Sendable {
    let name: String
    let displayName: String
    let remainingPercent: Double?
    let usedPercent: Double?
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let resetTime: String?
    let sourceDescription: String?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case remainingPercent = "remaining_percent"
        case usedPercent = "used_percent"
        case used
        case limit
        case remaining
        case resetTime = "reset_time"
        case sourceDescription = "source_description"
    }
}

// MARK: - URLSession Delegate

private final class SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let clientId: String
    private let verifySSL: Bool
    
    init(clientId: String, verifySSL: Bool = true) {
        self.clientId = clientId
        self.verifySSL = verifySSL
        super.init()
    }
    
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let errorMsg = error?.localizedDescription ?? "none"
        Log.api("[\(clientId)] Session invalidated, error=\(errorMsg)")
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard ManagementAPIClient.enableDiagnosticLogging else { return }
        
        for metric in metrics.transactionMetrics {
            let connectionType = metric.isReusedConnection ? "reused" : "new"
            let durationSec = metric.responseEndDate?.timeIntervalSince(metric.requestStartDate ?? Date()) ?? 0
            let durationStr = String(format: "%.3f", durationSec)
            Log.api("[\(clientId)] Connection: \(connectionType), duration=\(durationStr)s")
        }
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !verifySSL && challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Response Types

nonisolated struct LogsResponse: Codable, Sendable {
    let lines: [String]?
    let lineCount: Int?
    let latestTimestamp: Int?
    
    enum CodingKeys: String, CodingKey {
        case lines
        case lineCount = "line-count"
        case latestTimestamp = "latest-timestamp"
    }
}

nonisolated struct AuthFileModelsResponse: Codable, Sendable {
    let models: [AuthFileModelInfo]
}

nonisolated struct AuthFileModelInfo: Codable, Sendable {
    let id: String
    let ownedBy: String?
    let type: String?
    
    enum CodingKeys: String, CodingKey {
        case id, type
        case ownedBy = "owned_by"
    }
}

nonisolated struct APICallRequest: Codable, Sendable {
    let authIndex: String?
    let method: String
    let url: String
    let header: [String: String]?
    let data: String?
    
    enum CodingKeys: String, CodingKey {
        case method, url, header, data
        case authIndex = "auth_index"
    }
}

nonisolated struct APICallResponse: Codable, Sendable {
    let statusCode: Int
    let header: [String: [String]]?
    let body: String?
    
    enum CodingKeys: String, CodingKey {
        case header, body
        case statusCode = "status_code"
    }
}

nonisolated enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(String)
    case connectionError(String)
    case urlError(URLError)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .httpError(401): return "Unauthorized: check the management key"
        case .httpError(403): return "Forbidden: management access is not allowed"
        case .httpError(404): return "Unsupported endpoint: requires cpa-plusplus API support"
        case .httpError(let code) where 500...599 ~= code: return "Server error: \(code)"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .connectionError(let msg): return "Connection error: \(msg)"
        case .urlError(let error):
            switch error.code {
            case .timedOut:
                return "Request timed out"
            case .cannotConnectToHost, .networkConnectionLost:
                return "Connection refused or lost"
            case .cannotFindHost, .dnsLookupFailed:
                return "Host not found"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "SSL verification failed"
            default:
                return "Connection error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Remote Configuration Response Types

nonisolated struct RemoteProxyConfig: Codable, Sendable {
    let debug: Bool?
    let proxyURL: String?
    let routingStrategy: String?
    let requestRetry: Int?
    let maxRetryInterval: Int?
    let loggingToFile: Bool?
    let requestLog: Bool?
    let quotaExceeded: RemoteProxyQuotaExceededConfig?
    
    enum CodingKeys: String, CodingKey {
        case debug
        case proxyURL = "proxy-url"
        case routingStrategy = "routing-strategy"
        case requestRetry = "request-retry"
        case maxRetryInterval = "max-retry-interval"
        case loggingToFile = "logging-to-file"
        case requestLog = "request-log"
        case quotaExceeded = "quota-exceeded"
    }
}

nonisolated struct RemoteProxyQuotaExceededConfig: Codable, Sendable {
    let switchProject: Bool?
    let switchPreviewModel: Bool?
    
    enum CodingKeys: String, CodingKey {
        case switchProject = "switch-project"
        case switchPreviewModel = "switch-preview-model"
    }
}

nonisolated struct DebugResponse: Codable, Sendable {
    let debug: Bool
}

nonisolated struct ProxyURLResponse: Codable, Sendable {
    let proxyURL: String
    
    enum CodingKeys: String, CodingKey {
        case proxyURL = "proxy-url"
    }
}

nonisolated struct LoggingToFileResponse: Codable, Sendable {
    let loggingToFile: Bool
    
    enum CodingKeys: String, CodingKey {
        case loggingToFile = "logging-to-file"
    }
}

nonisolated struct RequestLogResponse: Codable, Sendable {
    let requestLog: Bool
    
    enum CodingKeys: String, CodingKey {
        case requestLog = "request-log"
    }
}

nonisolated struct RequestRetryResponse: Codable, Sendable {
    let requestRetry: Int
    
    enum CodingKeys: String, CodingKey {
        case requestRetry = "request-retry"
    }
}

nonisolated struct MaxRetryIntervalResponse: Codable, Sendable {
    let maxRetryInterval: Int
    
    enum CodingKeys: String, CodingKey {
        case maxRetryInterval = "max-retry-interval"
    }
}

nonisolated struct SwitchProjectResponse: Codable, Sendable {
    let switchProject: Bool
    
    enum CodingKeys: String, CodingKey {
        case switchProject = "switch-project"
    }
}

nonisolated struct SwitchPreviewModelResponse: Codable, Sendable {
    let switchPreviewModel: Bool
    
    enum CodingKeys: String, CodingKey {
        case switchPreviewModel = "switch-preview-model"
    }
}

nonisolated struct RoutingStrategyResponse: Codable, Sendable {
    let strategy: String
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let strategy = try container.decodeIfPresent(String.self, forKey: .strategy) {
            self.strategy = strategy
        } else if let strategy = try container.decodeIfPresent(String.self, forKey: .value) {
            self.strategy = strategy
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.strategy,
                .init(codingPath: decoder.codingPath, debugDescription: "Neither 'strategy' nor 'value' key found")
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strategy, forKey: .strategy)
    }
    
    private enum CodingKeys: String, CodingKey {
        case strategy
        case value
    }
}
