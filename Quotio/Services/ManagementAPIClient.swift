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
        
        let config = Self.makeSessionConfiguration(timeoutConfig: timeoutConfig)
        
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
        
        let config = Self.makeSessionConfiguration(timeoutConfig: timeoutConfig)
        
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

    private static func makeSessionConfiguration(timeoutConfig: TimeoutConfig) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutConfig.requestTimeout
        config.timeoutIntervalForResource = timeoutConfig.resourceTimeout
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        applyHTTPProxyOverride(to: config)

        return config
    }

    private static func applyHTTPProxyOverride(to config: URLSessionConfiguration) {
        let rawValue = ProcessInfo.processInfo.environment["QUOTIO_HTTP_PROXY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else { return }

        guard let url = URL(string: rawValue),
              let host = url.host,
              let port = url.port,
              url.scheme == "http" || url.scheme == "https" else {
            Log.warning("Ignoring invalid QUOTIO_HTTP_PROXY value. Expected http://host:port or https://host:port")
            return
        }

        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port
        ]

        Log.api("Management API HTTP proxy override enabled via QUOTIO_HTTP_PROXY=\(url.scheme ?? "http")://\(host):\(port)")
    }
    
    private func makeRequest(_ endpoint: String, method: String = "GET", body: Data? = nil, retryCount: Int = 0) async throws -> Data {
        let (data, _) = try await makeDataRequest(endpoint, method: method, body: body, retryCount: retryCount)
        return data
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func queryEndpoint(_ path: String, items: [URLQueryItem]) -> String {
        let filteredItems = items.filter { item in
            guard let value = item.value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !filteredItems.isEmpty else { return path }

        var components = URLComponents()
        components.path = path
        components.queryItems = filteredItems
        return components.string ?? path
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
                if let apiError = Self.apiError(statusCode: httpResponse.statusCode, data: data) {
                    throw apiError
                }
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

    private nonisolated static func apiError(statusCode: Int, data: Data) -> APIError? {
        guard let response = try? JSONDecoder().decode(ManagementErrorResponse.self, from: data) else {
            return nil
        }
        guard let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        return .apiError(statusCode: statusCode, code: response.error, message: message)
    }
    
    func fetchAuthFiles() async throws -> [AuthFile] {
        do {
            return try await fetchProviders().map(\.authFile)
        } catch APIError.httpError(404) {
            let data = try await makeRequest("/auth-files")
            let response = try decode(AuthFilesResponse.self, from: data)
            return response.files
        }
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
        do {
            _ = try await makeRequest("/providers/\(name.urlPathEncoded)", method: "DELETE")
        } catch APIError.httpError(404) {
            _ = try await makeRequest("/auth-files?name=\(name.urlQueryEncoded)", method: "DELETE")
        }
    }
    
    func setAuthFileDisabled(name: String, disabled: Bool) async throws {
        do {
            let body = try JSONEncoder().encode(["disabled": disabled])
            _ = try await makeRequest("/providers/\(name.urlPathEncoded)", method: "PATCH", body: body)
        } catch APIError.httpError(404) {
            struct Request: Encodable {
                let name: String
                let disabled: Bool
            }
            let body = try JSONEncoder().encode(Request(name: name, disabled: disabled))
            _ = try await makeRequest("/auth-files/status", method: "PATCH", body: body)
        }
    }

    func fetchProviders() async throws -> [ProviderResponse] {
        let data = try await makeRequest("/providers")
        let response = try decode(ProvidersResponse.self, from: data)
        return response.providers
    }

    func fetchModelCatalog() async throws -> ManagementModelCatalog {
        do {
            let data = try await makeRequest("/models/catalog")
            let response = try decode(ManagementModelCatalogAPIResponse.self, from: data)
            return response.catalog
        } catch APIError.httpError(404) {
            return try await fetchLegacyModelCatalog()
        }
    }

    private func fetchLegacyModelCatalog() async throws -> ManagementModelCatalog {
        let providers = try await fetchProviders()
        let targets = (try? await fetchVirtualModelAvailableTargets())?.targets ?? []
        let providerIDs = Set(
            providers.map { Self.normalizedProviderID($0.provider) }
                + targets.map { Self.normalizedProviderID($0.provider) }
        )

        var definitionsByProvider: [String: [String: ManagementModelDefinition]] = [:]
        for providerID in providerIDs.sorted() {
            guard let channel = Self.modelDefinitionChannel(for: providerID) else { continue }
            guard let response = try? await fetchModelDefinitions(channel: channel) else { continue }

            var definitions: [String: ManagementModelDefinition] = [:]
            for definition in response.models {
                let modelID = Self.normalizedModelID(definition.id, providerID: providerID)
                definitions[modelID] = definition
                definitions[definition.id] = definition
            }
            definitionsByProvider[providerID] = definitions
        }

        return ManagementModelCatalog(
            providers: ManagementModelCatalog.buildProviders(
                providers: providers,
                targets: targets,
                definitionsByProvider: definitionsByProvider
            )
        )
    }

    func updateProviderEnabledModels(providerID: String, enabledModels: [String]?) async throws {
        let body = try JSONEncoder().encode(ProviderEnabledModelsUpdateRequest(enabledModels: enabledModels))
        _ = try await makeRequest("/providers/\(providerID.urlPathEncoded)/enabled-models", method: "PUT", body: body)
    }

    private func fetchModelDefinitions(channel: String) async throws -> ManagementModelDefinitionsResponse {
        let data = try await makeRequest("/model-definitions/\(channel.urlPathEncoded)")
        return try decode(ManagementModelDefinitionsResponse.self, from: data)
    }

    func fetchVirtualModelsConfiguration() async throws -> VirtualModelsConfiguration {
        let data = try await makeRequest("/virtual-models")
        return try decode(VirtualModelsConfiguration.self, from: data)
    }

    func updateVirtualModelsConfiguration(_ configuration: VirtualModelsConfiguration) async throws {
        let body = try JSONEncoder().encode(configuration)
        _ = try await makeRequest("/virtual-models", method: "PUT", body: body)
    }

    func setVirtualModelsEnabled(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(VirtualModelsEnabledUpdate(enabled: enabled))
        _ = try await makeRequest("/virtual-models/enabled", method: "PATCH", body: body)
    }

    func fetchVirtualModelAvailableTargets() async throws -> VirtualModelAvailableTargetsResponse {
        let data = try await makeRequest("/virtual-models/available-targets")
        return try decode(VirtualModelAvailableTargetsResponse.self, from: data)
    }

    func refreshProvider(id: String) async throws -> ProviderResponse {
        let data = try await makeRequest("/providers/\(id.urlPathEncoded)/refresh", method: "POST")
        return try decode(ProviderResponse.self, from: data)
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
            endpoint = "/quota/refresh/\(provider.canonicalProviderID.urlPathEncoded)/\(authID.urlPathEncoded)"
        } else {
            endpoint = "/quota/refresh"
        }
        let data = try await makeRequest(endpoint, method: "POST")
        return try decode(ManagementQuotaView.self, from: data)
    }

    func fetchQuota(provider: AIProvider) async throws -> ManagementQuotaView {
        let data = try await makeRequest("/quota/providers/\(provider.canonicalProviderID.urlPathEncoded)")
        return try decode(ManagementQuotaView.self, from: data)
    }
    
    func startProviderOAuth(provider: AIProvider, method: ProviderOAuthMethod? = nil, options: [String: String] = [:]) async throws -> ProviderOAuthSession {
        var request: [String: Any] = ["provider": provider.canonicalProviderID]
        if let method {
            request["method"] = method.rawValue
        }
        if !options.isEmpty {
            request["options"] = options
        }
        let data = try await makeRequest("/providers/oauth/start", method: "POST", body: try jsonBody(request))
        return try decode(ProviderOAuthSession.self, from: data)
    }

    func fetchProviderOAuthSession(_ sessionID: String) async throws -> ProviderOAuthSession {
        let data = try await makeRequest("/providers/oauth/sessions/\(sessionID.urlPathEncoded)")
        return try decode(ProviderOAuthSession.self, from: data)
    }

    func cancelProviderOAuthSession(_ sessionID: String) async throws -> ProviderOAuthSession {
        let data = try await makeRequest("/providers/oauth/sessions/\(sessionID.urlPathEncoded)", method: "DELETE")
        return try decode(ProviderOAuthSession.self, from: data)
    }

    func completeProviderOAuthCallback(sessionID: String, state: String, code: String) async throws -> ProviderOAuthSession {
        let body = try JSONEncoder().encode(ProviderOAuthCallbackRequest(sessionID: sessionID, state: state, code: code))
        let data = try await makeRequest("/providers/oauth/callback", method: "POST", body: body)
        return try decode(ProviderOAuthSession.self, from: data)
    }
    
    func fetchLogs(limit: Int? = nil, after: Int? = nil) async throws -> LogsResponse {
        var items: [URLQueryItem] = []
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let after = after {
            items.append(URLQueryItem(name: "after", value: String(after)))
        }
        let endpoint = queryEndpoint("/logs", items: items)
        let data = try await makeRequest(endpoint)
        return try decode(LogsResponse.self, from: data)
    }

    func fetchLogs(after: Int? = nil) async throws -> LogsResponse {
        try await fetchLogs(limit: nil, after: after)
    }
    
    func clearLogs() async throws {
        _ = try await makeRequest("/logs", method: "DELETE")
    }

    func fetchRequestErrorLogs() async throws -> [RequestErrorLogFile] {
        let data = try await makeRequest("/request-error-logs")
        let response = try decode(RequestErrorLogsResponse.self, from: data)
        return response.files
    }

    func fetchRequestErrorLog(name: String) async throws -> Data {
        try await makeRequest("/request-error-logs/\(name.urlPathEncoded)")
    }

    func fetchRequestLogByID(_ id: String) async throws -> Data {
        try await makeRequest("/request-log-by-id/\(id.urlPathEncoded)")
    }

    func fetchUsageStatsStatus() async throws -> UsageStatsStatus {
        let data = try await makeRequest("/usage-stats/status")
        return try decode(UsageStatsStatus.self, from: data)
    }

    func fetchUsageStatsEvents(filter: UsageStatsFilter, limit: Int, offset: Int) async throws -> UsageStatsEventsResponse {
        var items = filter.queryItems
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        items.append(URLQueryItem(name: "offset", value: String(offset)))
        let data = try await makeRequest(queryEndpoint("/usage-stats/events", items: items))
        return try decode(UsageStatsEventsResponse.self, from: data)
    }

    func fetchUsageStatsSummary(filter: UsageStatsFilter, includeCost: Bool = true) async throws -> UsageStatsSummary {
        var items = filter.queryItems
        items.append(URLQueryItem(name: "include_cost", value: includeCost ? "true" : "false"))
        let data = try await makeRequest(queryEndpoint("/usage-stats/summary", items: items))
        let response = try decode(UsageStatsSummaryResponse.self, from: data)
        return response.summary
    }

    func syncUsageStatsModelPrices(models: [String] = [], includePrices: Bool = false) async throws -> UsageStatsModelPricesSyncResult {
        let body = try JSONEncoder().encode(UsageStatsModelPricesSyncRequest(models: models, includePrices: includePrices))
        let data = try await makeRequest("/usage-stats/model-prices/sync", method: "POST", body: body)
        return try decode(UsageStatsModelPricesSyncResult.self, from: data)
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
    
    // MARK: - Proxy Health

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

private extension String {
    nonisolated var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    nonisolated var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

// MARK: - Canonical Provider API Types

nonisolated struct ProvidersResponse: Decodable, Sendable {
    let providers: [ProviderResponse]

    init(from decoder: Decoder) throws {
        if let array = try? [ProviderResponse](from: decoder) {
            providers = array
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([ProviderResponse].self, forKey: .providers)
    }

    private enum CodingKeys: String, CodingKey {
        case providers
    }
}

nonisolated struct ProviderResponse: Codable, Sendable {
    let id: String
    let type: String?
    let provider: String
    let label: String?
    let disabled: Bool
    let projectID: String?
    let excludedModels: [String]?
    let validation: ProviderValidation?

    enum CodingKeys: String, CodingKey {
        case id, type, provider, label, disabled, validation
        case projectID = "project_id"
        case excludedModels = "excluded_models"
    }

    var authFile: AuthFile {
        let valid = validation?.valid ?? !disabled
        let accountIdentity = validation?.accountIdentity
        let warning = validation?.warnings?.joined(separator: "\n")
        let statusMessage = validation?.error ?? warning

        return AuthFile(
            id: id,
            name: id,
            provider: provider,
            label: label,
            status: disabled ? "disabled" : (valid ? "ready" : "error"),
            statusMessage: statusMessage,
            disabled: disabled,
            unavailable: !valid,
            runtimeOnly: nil,
            source: "providers",
            path: nil,
            email: accountIdentity,
            accountType: type,
            account: accountIdentity,
            authIndex: id,
            createdAt: nil,
            updatedAt: validation?.checkedAt,
            lastRefresh: validation?.checkedAt
        )
    }
}

nonisolated struct ProviderValidation: Codable, Sendable {
    let valid: Bool?
    let authType: String?
    let supportedModels: [String]?
    let accountIdentity: String?
    let expiresAt: String?
    let warnings: [String]?
    let checkedAt: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case valid, warnings, error
        case authType = "auth_type"
        case supportedModels = "supported_models"
        case accountIdentity = "account_identity"
        case expiresAt = "expires_at"
        case checkedAt = "checked_at"
    }
}

// MARK: - Model Catalog Types

private nonisolated struct ProviderEnabledModelsUpdateRequest: Encodable, Sendable {
    let enabledModels: [String]?

    enum CodingKeys: String, CodingKey {
        case enabledModels = "enabled_models"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let enabledModels {
            try container.encode(enabledModels, forKey: .enabledModels)
        } else {
            try container.encodeNil(forKey: .enabledModels)
        }
    }
}

private nonisolated struct ManagementErrorResponse: Decodable, Sendable {
    let error: String
    let message: String?
}

// MARK: - Virtual Model Types

private nonisolated struct VirtualModelsEnabledUpdate: Encodable, Sendable {
    let enabled: Bool
}

nonisolated struct VirtualModelsConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var cacheTTL: String
    var maxDepth: Int
    var virtualModels: [String: VirtualModelRouteConfiguration]

    enum CodingKeys: String, CodingKey {
        case enabled
        case cacheTTL = "cache_ttl"
        case maxDepth = "max_depth"
        case virtualModels = "virtual_models"
    }

    init(
        enabled: Bool = true,
        cacheTTL: String = "30s",
        maxDepth: Int = 5,
        virtualModels: [String: VirtualModelRouteConfiguration] = [:]
    ) {
        self.enabled = enabled
        self.cacheTTL = cacheTTL
        self.maxDepth = maxDepth
        self.virtualModels = virtualModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cacheTTL = try container.decodeIfPresent(String.self, forKey: .cacheTTL) ?? "30s"
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? 5
        virtualModels = try container.decodeIfPresent(
            [String: VirtualModelRouteConfiguration].self,
            forKey: .virtualModels
        ) ?? [:]
    }
}

nonisolated struct VirtualModelRouteConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var targets: [VirtualModelTargetConfiguration]

    enum CodingKeys: String, CodingKey {
        case enabled
        case targets
    }

    init(enabled: Bool = true, targets: [VirtualModelTargetConfiguration] = []) {
        self.enabled = enabled
        self.targets = targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        targets = try container.decodeIfPresent([VirtualModelTargetConfiguration].self, forKey: .targets) ?? []
    }
}

nonisolated struct VirtualModelTargetConfiguration: Codable, Equatable, Sendable {
    var target: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case target
        case enabled
    }

    init(target: String, enabled: Bool = true) {
        self.target = target
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(String.self, forKey: .target)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

private nonisolated struct ManagementModelCatalogAPIResponse: Decodable, Sendable {
    let providers: [ManagementModelCatalogAPIProvider]

    var catalog: ManagementModelCatalog {
        ManagementModelCatalog(
            providers: providers.map(\.catalogProvider)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }
}

private nonisolated struct ManagementModelCatalogAPIProvider: Decodable, Sendable {
    let providerID: String
    let providerName: String
    let models: [ManagementModelCatalogAPIItem]

    enum CodingKeys: String, CodingKey {
        case models
        case providerID = "provider_id"
        case providerName = "provider_name"
    }

    var catalogProvider: ManagementModelCatalogProvider {
        let normalizedProviderID = ManagementAPIClient.normalizedProviderID(providerID)
        return ManagementModelCatalogProvider(
            id: normalizedProviderID,
            name: providerName,
            models: models.map { $0.catalogItem(providerID: normalizedProviderID, providerName: providerName) }
                .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
        )
    }
}

private nonisolated struct ManagementModelCatalogAPIItem: Decodable, Sendable {
    let id: String
    let modelID: String
    let provider: String
    let type: String?
    let displayName: String?
    let name: String?
    let ownedBy: String?
    let contextWindow: Int?
    let maxOutputTokens: Int?
    let available: Bool
    let isEnabled: Bool
    let capabilities: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id, provider, type, name, available, capabilities
        case modelID = "model_id"
        case displayName = "display_name"
        case ownedBy = "owned_by"
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
        case isEnabled = "is_enabled"
    }

    func catalogItem(providerID: String, providerName: String) -> ManagementModelCatalogItem {
        let normalizedModelID = ManagementAPIClient.normalizedModelID(modelID, providerID: providerID)
        return ManagementModelCatalogItem(
            id: "\(providerID)::\(normalizedModelID)",
            providerID: providerID,
            providerName: providerName,
            modelID: normalizedModelID,
            displayName: displayName ?? name,
            ownedBy: ownedBy,
            contextLength: contextWindow,
            maxOutputTokens: maxOutputTokens,
            isEnabled: isEnabled,
            isAvailable: available,
            capabilities: ManagementModelCapability.fromCatalog(capabilities, modelID: normalizedModelID, type: type)
        )
    }
}

nonisolated struct ManagementModelCatalog: Sendable {
    let providers: [ManagementModelCatalogProvider]

    var rows: [ManagementModelCatalogItem] {
        providers.flatMap(\.models)
    }

    static func buildProviders(
        providers: [ProviderResponse],
        targets: [VirtualModelAvailableTarget],
        definitionsByProvider: [String: [String: ManagementModelDefinition]]
    ) -> [ManagementModelCatalogProvider] {
        let providersByID = Dictionary(grouping: providers) { ManagementAPIClient.normalizedProviderID($0.provider) }
        let targetsByID = Dictionary(grouping: targets) { ManagementAPIClient.normalizedProviderID($0.provider) }
        let providerIDs = Set(Array(providersByID.keys) + Array(targetsByID.keys))

        return providerIDs.compactMap { providerID -> ManagementModelCatalogProvider? in
            let credentials = providersByID[providerID] ?? []
            let targetModelIDs = Set((targetsByID[providerID] ?? []).map {
                ManagementAPIClient.normalizedModelID($0.model, providerID: providerID)
            })
            var modelIDs = Set<String>()

            for credential in credentials {
                for modelID in credential.validation?.supportedModels ?? [] {
                    modelIDs.insert(ManagementAPIClient.normalizedModelID(modelID, providerID: providerID))
                }
            }
            modelIDs.formUnion(targetModelIDs)

            let hasUsableCredential = credentials.contains { credential in
                !credential.disabled && (credential.validation?.valid ?? true)
            }
            if modelIDs.isEmpty, hasUsableCredential, let definitions = definitionsByProvider[providerID] {
                modelIDs.formUnion(definitions.keys)
            }

            guard !modelIDs.isEmpty else { return nil }

            let aiProvider = AIProvider.fromProviderID(providerID)
            let providerName = aiProvider?.displayName ?? providerID
            let activeCredentials = credentials.filter { !$0.disabled && ($0.validation?.valid ?? true) }
            let providerHasCredentials = !credentials.isEmpty
            let providerIsAvailable = !providerHasCredentials || !activeCredentials.isEmpty || !targetModelIDs.isEmpty

            let models = modelIDs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { modelID in
                let definition = definitionsByProvider[providerID]?[modelID]
                    ?? definitionsByProvider[providerID]?[ManagementAPIClient.prefixedModelID(providerID: providerID, modelID: modelID)]
                let excludedCount = credentials.filter { credential in
                    let excluded = Set((credential.excludedModels ?? []).map {
                        ManagementAPIClient.normalizedModelID($0, providerID: providerID)
                    })
                    return excluded.contains(modelID)
                }.count
                let enabledByExclusions = credentials.isEmpty || excludedCount < credentials.count

                return ManagementModelCatalogItem(
                    id: "\(providerID)::\(modelID)",
                    providerID: providerID,
                    providerName: providerName,
                    modelID: modelID,
                    displayName: definition?.displayName ?? definition?.name,
                    ownedBy: definition?.ownedBy,
                    contextLength: definition?.contextLength ?? definition?.inputTokenLimit,
                    maxOutputTokens: definition?.maxCompletionTokens ?? definition?.outputTokenLimit,
                    isEnabled: providerIsAvailable && enabledByExclusions,
                    isAvailable: providerIsAvailable,
                    capabilities: ManagementModelCapability.infer(from: definition, modelID: modelID)
                )
            }

            return ManagementModelCatalogProvider(
                id: providerID,
                name: providerName,
                models: models
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

nonisolated struct ManagementModelCatalogProvider: Identifiable, Sendable {
    let id: String
    let name: String
    let models: [ManagementModelCatalogItem]
}

nonisolated struct ManagementModelCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let providerID: String
    let providerName: String
    let modelID: String
    let displayName: String?
    let ownedBy: String?
    let contextLength: Int?
    let maxOutputTokens: Int?
    let isEnabled: Bool
    let isAvailable: Bool
    let capabilities: [ManagementModelCapability]

    var routeID: String {
        ManagementAPIClient.prefixedModelID(providerID: providerID, modelID: modelID)
    }
}

nonisolated struct ManagementModelCapability: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let localizationKey: String

    static func fromCatalog(_ capabilities: [String: Bool]?, modelID: String, type: String?) -> [ManagementModelCapability] {
        let enabledCapabilities = Set((capabilities ?? [:]).compactMap { key, isEnabled -> String? in
            guard isEnabled else { return nil }
            switch key.lowercased() {
            case "embedding", "embeddings":
                return "embedding"
            case "reasoning", "vision", "tools", "free", "rerank":
                return key.lowercased()
            default:
                return nil
            }
        })

        let ordered: [ManagementModelCapability] = [
            .init(id: "reasoning", label: "R", localizationKey: "models.capability.reasoning"),
            .init(id: "vision", label: "V", localizationKey: "models.capability.vision"),
            .init(id: "tools", label: "T", localizationKey: "models.capability.tools"),
            .init(id: "free", label: "F", localizationKey: "models.capability.free"),
            .init(id: "embedding", label: "E", localizationKey: "models.capability.embedding"),
            .init(id: "rerank", label: "RR", localizationKey: "models.capability.rerank")
        ]
        let fromCatalog = ordered.filter { enabledCapabilities.contains($0.id) }
        if !fromCatalog.isEmpty {
            return fromCatalog
        }

        return infer(from: nil, modelID: [modelID, type ?? ""].joined(separator: " "))
    }

    static func infer(from definition: ManagementModelDefinition?, modelID: String) -> [ManagementModelCapability] {
        let loweredID = modelID.lowercased()
        let inputModalities = Set((definition?.supportedInputModalities ?? []).map { $0.lowercased() })
        let parameters = Set((definition?.supportedParameters ?? []).map { $0.lowercased() })
        let type = definition?.type?.lowercased() ?? ""
        var capabilities: [ManagementModelCapability] = []

        if definition?.thinking != nil
            || loweredID.contains("reasoning")
            || loweredID.contains("thinking")
            || loweredID.contains("opus")
            || loweredID.contains("o1")
            || loweredID.contains("o3")
            || loweredID.contains("o4") {
            capabilities.append(.init(id: "reasoning", label: "R", localizationKey: "models.capability.reasoning"))
        }

        if inputModalities.contains("image")
            || inputModalities.contains("vision")
            || inputModalities.contains("video")
            || loweredID.contains("vision")
            || loweredID.contains("image")
            || loweredID.contains("-vl") {
            capabilities.append(.init(id: "vision", label: "V", localizationKey: "models.capability.vision"))
        }

        if parameters.contains("tools")
            || parameters.contains("tool_choice")
            || parameters.contains("functions")
            || parameters.contains("function_call")
            || loweredID.contains("tool") {
            capabilities.append(.init(id: "tools", label: "T", localizationKey: "models.capability.tools"))
        }

        if loweredID.contains("free") || loweredID.contains("mini") || loweredID.contains("lite") {
            capabilities.append(.init(id: "free", label: "F", localizationKey: "models.capability.free"))
        }

        if type.contains("embedding") || loweredID.contains("embed") {
            capabilities.append(.init(id: "embedding", label: "E", localizationKey: "models.capability.embedding"))
        }

        if loweredID.contains("rerank") {
            capabilities.append(.init(id: "rerank", label: "RR", localizationKey: "models.capability.rerank"))
        }

        return capabilities
    }
}

nonisolated struct ManagementModelDefinitionsResponse: Decodable, Sendable {
    let channel: String
    let models: [ManagementModelDefinition]
}

nonisolated struct ManagementModelDefinition: Decodable, Sendable {
    let id: String
    let object: String?
    let created: Int?
    let ownedBy: String?
    let type: String?
    let displayName: String?
    let name: String?
    let version: String?
    let description: String?
    let inputTokenLimit: Int?
    let outputTokenLimit: Int?
    let contextLength: Int?
    let maxCompletionTokens: Int?
    let supportedParameters: [String]?
    let supportedInputModalities: [String]?
    let supportedOutputModalities: [String]?
    let thinking: ManagementModelThinking?

    enum CodingKeys: String, CodingKey {
        case id, object, created, type, name, version, description, thinking
        case ownedBy = "owned_by"
        case displayName = "display_name"
        case inputTokenLimit
        case outputTokenLimit
        case contextLength = "context_length"
        case maxCompletionTokens = "max_completion_tokens"
        case supportedParameters = "supported_parameters"
        case supportedInputModalities
        case supportedOutputModalities
    }
}

nonisolated struct ManagementModelThinking: Decodable, Sendable {
    let min: Int?
    let max: Int?
    let zeroAllowed: Bool?
    let dynamicAllowed: Bool?
    let levels: [String]?

    enum CodingKeys: String, CodingKey {
        case min, max, levels
        case zeroAllowed = "zero_allowed"
        case dynamicAllowed = "dynamic_allowed"
    }
}

nonisolated struct VirtualModelAvailableTargetsResponse: Codable, Sendable {
    let targets: [VirtualModelAvailableTarget]
}

nonisolated struct VirtualModelAvailableTarget: Codable, Hashable, Identifiable, Sendable {
    let provider: String
    let model: String
    let target: String

    var id: String { target }
}

nonisolated extension ManagementAPIClient {
    static func normalizedProviderID(_ providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AIProvider.fromProviderID(trimmed)?.canonicalProviderID ?? trimmed
    }

    static func modelDefinitionChannel(for providerID: String) -> String? {
        switch normalizedProviderID(providerID) {
        case "anthropic":
            return "claude"
        case "gemini":
            return "gemini-cli"
        case "github-copilot":
            return "github-copilot"
        case "codex", "antigravity", "kiro", "kimi", "xai", "vertex":
            return normalizedProviderID(providerID)
        default:
            return nil
        }
    }

    static func normalizedModelID(_ modelID: String, providerID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = normalizedProviderID(providerID)
        var aliases = Set([provider])
        if let aiProvider = AIProvider.fromProviderID(provider) {
            aliases.insert(aiProvider.rawValue)
            aliases.insert(aiProvider.canonicalProviderID)
        }
        if let channel = modelDefinitionChannel(for: provider) {
            aliases.insert(channel)
        }

        for alias in aliases where trimmed.lowercased().hasPrefix(alias.lowercased() + "/") {
            return String(trimmed.dropFirst(alias.count + 1))
        }
        return trimmed
    }

    static func prefixedModelID(providerID: String, modelID: String) -> String {
        "\(normalizedProviderID(providerID))/\(modelID)"
    }
}

// MARK: - Canonical OAuth API Types

nonisolated enum ProviderOAuthMethod: String, Codable, Sendable {
    case signinLocalhost = "signin_localhost"
    case deviceCode = "device_code"
    case builderIDDevice = "builder_id_device"
    case awsDevice = "aws_device"
    case builderIDAuthCode = "builder_id_auth_code"
    case idcDevice = "idc_device"
    case idcAuthCode = "idc_auth_code"
}

nonisolated enum ProviderOAuthSessionStatus: String, Codable, Sendable {
    case starting
    case awaitingCallback = "awaiting_callback"
    case awaitingDeviceConfirmation = "awaiting_device_confirmation"
    case completed
    case failed
    case expired
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .expired, .cancelled:
            return true
        case .starting, .awaitingCallback, .awaitingDeviceConfirmation:
            return false
        }
    }
}

nonisolated struct ProviderOAuthSession: Codable, Sendable {
    let sessionID: String
    let provider: String
    let status: ProviderOAuthSessionStatus
    let authURL: String?
    let verificationURI: String?
    let userCode: String?
    let expiresAt: String?
    let intervalSeconds: Int?
    let error: String?
    let credential: ProviderResponse?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case provider, status, error, credential, state
        case sessionID = "session_id"
        case authURL = "auth_url"
        case verificationURI = "verification_uri"
        case userCode = "user_code"
        case expiresAt = "expires_at"
        case intervalSeconds = "interval_seconds"
    }
}

nonisolated struct ProviderOAuthCallbackRequest: Encodable, Sendable {
    let sessionID: String
    let state: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
        case code
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
            let providerID = providerView.providerKey ?? providerView.provider
            guard let provider = AIProvider.fromProviderID(providerID) else { continue }
            for account in providerView.accounts ?? [] {
                let accountKey = account.accountKey ?? account.account ?? account.email ?? ""
                let credentialID = account.credentialID ?? account.authID ?? account.id ?? ""
                let key = quotaAccountKey(
                    provider: provider,
                    accountKey: accountKey,
                    credentialID: credentialID,
                    existing: result[provider] ?? [:]
                )
                guard !key.isEmpty else { continue }
                let rawUpdated = account.lastUpdated ?? account.lastRefresh ?? ""
                let lastUpdated = formatter.date(from: rawUpdated)
                    ?? fallbackFormatter.date(from: rawUpdated)
                    ?? Date()
                let models = (account.models ?? []).map { model in
                    ModelQuota(
                        name: (model.name ?? "").isEmpty ? (model.displayName ?? "Quota") : (model.name ?? "Quota"),
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
                    isForbidden: account.isForbidden ?? false,
                    planType: account.planDisplayName ?? account.planType,
                    error: account.error
                )
            }
        }
        return result
    }

    private func quotaAccountKey(
        provider: AIProvider,
        accountKey: String,
        credentialID: String,
        existing: [String: ProviderQuotaData]
    ) -> String {
        let normalizedCredentialID = provider == .codex ? credentialID.codexFilenameKey : credentialID
        let preferred = provider == .codex ? normalizedCredentialID : accountKey
        let fallback = provider == .codex ? accountKey : normalizedCredentialID
        let key = preferred.isEmpty ? fallback : preferred

        if !key.isEmpty, existing[key] == nil {
            return key
        }

        if !fallback.isEmpty, existing[fallback] == nil {
            return fallback
        }

        if !key.isEmpty, !normalizedCredentialID.isEmpty {
            return "\(key)::\(normalizedCredentialID)"
        }

        return key
    }
}

nonisolated struct ManagementQuotaProvider: Codable, Sendable {
    let provider: String
    let providerKey: String?
    let accounts: [ManagementQuotaAccount]?

    enum CodingKeys: String, CodingKey {
        case provider
        case providerKey = "provider_key"
        case accounts
    }
}

nonisolated struct ManagementQuotaAccount: Codable, Sendable {
    let id: String?
    let credentialID: String?
    let authID: String?
    let accountKey: String?
    let account: String?
    let email: String?
    let planType: String?
    let planDisplayName: String?
    let isForbidden: Bool?
    let lastUpdated: String?
    let lastRefresh: String?
    let error: String?
    let models: [ManagementQuotaModel]?

    enum CodingKeys: String, CodingKey {
        case id, account, email, error, models
        case credentialID = "credential_id"
        case authID = "auth_id"
        case accountKey = "account_key"
        case planType = "plan_type"
        case planDisplayName = "plan_display_name"
        case isForbidden = "is_forbidden"
        case lastUpdated = "last_updated"
        case lastRefresh = "last_refresh"
    }
}

nonisolated struct ManagementQuotaModel: Codable, Sendable {
    let name: String?
    let displayName: String?
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
    case apiError(statusCode: Int, code: String, message: String)
    case decodingError(String)
    case connectionError(String)
    case urlError(URLError)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .httpError(401): return "Unauthorized: check the management key"
        case .httpError(403): return "Forbidden: management access is not allowed"
        case .httpError(404): return "Unsupported endpoint: requires cpa++ API support"
        case .httpError(let code) where 500...599 ~= code: return "Server error: \(code)"
        case .httpError(let code): return "HTTP error: \(code)"
        case .apiError(_, _, let message): return message
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
