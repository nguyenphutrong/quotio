//
//  ManagementAPIClient.swift
//  CKota - CLIProxyAPI GUI Wrapper
//

import Foundation

actor ManagementAPIClient {
    private let baseURL: String
    private let authKey: String
    private let session: URLSession

    init(baseURL: String, authKey: String) {
        self.baseURL = baseURL
        self.authKey = authKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(_ endpoint: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200 ... 299 ~= httpResponse.statusCode else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        return data
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

    func getOAuthURL(for provider: AIProvider, projectId _: String? = nil) async throws -> OAuthURLResponse {
        var endpoint = provider.oauthEndpoint + "?is_webui=true"
        let data = try await makeRequest(endpoint)
        return try JSONDecoder().decode(OAuthURLResponse.self, from: data)
    }

    func pollOAuthStatus(state: String) async throws -> OAuthStatusResponse {
        let data = try await makeRequest("/get-auth-status?state=\(state)")
        return try JSONDecoder().decode(OAuthStatusResponse.self, from: data)
    }

    func fetchLogs(after: Int? = nil) async throws -> LogsResponse {
        var endpoint = "/logs"
        if let after {
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
}

struct LogsResponse: Codable, Sendable {
    let lines: [String]?
    let lineCount: Int?
    let latestTimestamp: Int?

    enum CodingKeys: String, CodingKey {
        case lines
        case lineCount = "line-count"
        case latestTimestamp = "latest-timestamp"
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .invalidResponse: "Invalid response"
        case let .httpError(code): "HTTP error: \(code)"
        case let .decodingError(msg): "Decoding error: \(msg)"
        }
    }
}
