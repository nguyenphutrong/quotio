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
    
    // MARK: - Diagnostic Logging
    
    static let enableDiagnosticLogging = false
    nonisolated(unsafe) private static var activeRequests: Int = 0
    private static let requestLock = NSLock()
    
    private static func log(_ message: String) {
        guard enableDiagnosticLogging else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[API \(timestamp)] \(message)")
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
    
    init(baseURL: String, authKey: String) {
        self.baseURL = baseURL
        self.authKey = authKey
        self.clientId = String(UUID().uuidString.prefix(6))
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15  // Increased from 10
        config.timeoutIntervalForResource = 45 // Increased from 30
        // Increased connection limit to handle concurrent requests better
        config.httpMaximumConnectionsPerHost = 4
        // Disable connection caching to prevent stale connections
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        self.sessionDelegate = SessionDelegate(clientId: clientId)
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        
        Self.log("[\(clientId)] Client created, maxConnections=4, timeout=15/45s")
    }
    
    func invalidate() {
        Self.log("[\(clientId)] Session invalidating...")
        session.invalidateAndCancel()
    }
    
    private func makeRequest(_ endpoint: String, method: String = "GET", body: Data? = nil, retryCount: Int = 0) async throws -> Data {
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
            
            return data
        } catch let error as URLError {
            Self.log("[\(clientId)][\(requestId)] URL ERROR: \(error.code.rawValue) - \(error.localizedDescription)")
            
            // Retry once on timeout or connection errors (stale connection recovery)
            if retryCount < 1 && (error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cannotConnectToHost) {
                Self.log("[\(clientId)][\(requestId)] RETRYING after 0.5s...")
                // Small delay before retry
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                return try await makeRequest(endpoint, method: method, body: body, retryCount: retryCount + 1)
            }
            throw APIError.connectionError(error.localizedDescription)
        } catch {
            Self.log("[\(clientId)][\(requestId)] UNEXPECTED ERROR: \(error.localizedDescription)")
            throw error
        }
    }
    
    func fetchAuthFiles() async throws -> [AuthFile] {
        let data = try await makeRequest("/auth-files")
        let response = try JSONDecoder().decode(AuthFilesResponse.self, from: data)
        return response.files
    }
    
    func deleteAuthFile(name: String) async throws {
        _ = try await makeRequest("/auth-files?name=\(name)", method: "DELETE")
    }
    
    func deleteAllAuthFiles() async throws {
        _ = try await makeRequest("/auth-files?all=true", method: "DELETE")
    }
    
    func fetchUsageStats() async throws -> UsageStats {
        let data = try await makeRequest("/usage")
        return try JSONDecoder().decode(UsageStats.self, from: data)
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
        return try JSONDecoder().decode(OAuthURLResponse.self, from: data)
    }
    
    func pollOAuthStatus(state: String) async throws -> OAuthStatusResponse {
        let data = try await makeRequest("/get-auth-status?state=\(state)")
        return try JSONDecoder().decode(OAuthStatusResponse.self, from: data)
    }
    
    func fetchLogs(after: Int? = nil) async throws -> LogsResponse {
        var endpoint = "/logs"
        if let after = after {
            endpoint += "?after=\(after)"
        }
        let data = try await makeRequest(endpoint)
        return try JSONDecoder().decode(LogsResponse.self, from: data)
    }
    
    func clearLogs() async throws {
        _ = try await makeRequest("/logs", method: "DELETE")
    }
    
    func setDebug(_ enabled: Bool) async throws {
        let body = try JSONEncoder().encode(["value": enabled])
        _ = try await makeRequest("/debug", method: "PUT", body: body)
    }
    
    func setRoutingStrategy(_ strategy: String) async throws {
        let body = try JSONEncoder().encode(["strategy": strategy])
        _ = try await makeRequest("/routing", method: "PUT", body: body)
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
        let response = try JSONDecoder().decode(APIKeysResponse.self, from: data)
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
        return try JSONDecoder().decode(LatestVersionResponse.self, from: data)
    }
    
    /// Check if proxy is responding by calling the debug endpoint.
    /// This is simpler than /health which may not exist.
    func checkProxyResponding() async -> Bool {
        do {
            _ = try await makeRequest("/debug")
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Latest Version Response

nonisolated struct LatestVersionResponse: Codable, Sendable {
    let latestVersion: String
    
    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest-version"
    }
}

// MARK: - URLSession Delegate

private final class SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let clientId: String
    
    init(clientId: String) {
        self.clientId = clientId
        super.init()
    }
    
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let errorMsg = error?.localizedDescription ?? "none"
        print("[API] [\(clientId)] Session invalidated, error=\(errorMsg)")
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard ManagementAPIClient.enableDiagnosticLogging else { return }
        
        for metric in metrics.transactionMetrics {
            let reused = metric.isReusedConnection ? "reused" : "new"
            let duration = metric.responseEndDate?.timeIntervalSince(metric.requestStartDate ?? Date()) ?? 0
            print("[API] [\(clientId)] Connection: \(reused), duration=\(String(format: "%.3f", duration))s")
        }
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

nonisolated enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(String)
    case connectionError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .connectionError(let msg): return "Connection error: \(msg)"
        }
    }
}
