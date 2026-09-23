import Foundation
import QuotioApplication

public actor ManagementAPIClient: ProxyLogRepository {
    public struct Connection: Sendable {
        public let baseURL: String
        public let authKey: String

        public init(baseURL: String, authKey: String) {
            self.baseURL = baseURL
            self.authKey = authKey
        }
    }

    public typealias ConnectionProvider = @Sendable () async -> Connection

    private let connectionProvider: ConnectionProvider
    private let session: URLSession

    public init(connectionProvider: @escaping ConnectionProvider) {
        self.connectionProvider = connectionProvider
        self.session = .shared
    }

    init(
        connectionProvider: @escaping ConnectionProvider,
        session: URLSession
    ) {
        self.connectionProvider = connectionProvider
        self.session = session
    }

    public func fetchLogs(after timestamp: Int?) async throws -> ProxyLogPage {
        let request = try await makeRequest(method: "GET", after: timestamp)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let payload = try JSONDecoder().decode(LogsResponse.self, from: data)
        return ProxyLogPage(
            lines: payload.lines ?? [],
            latestTimestamp: payload.latestTimestamp
        )
    }

    public func clearLogs() async throws {
        let request = try await makeRequest(method: "DELETE", after: nil)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func makeRequest(method: String, after timestamp: Int?) async throws -> URLRequest {
        let connection = await connectionProvider()
        guard var components = URLComponents(string: connection.baseURL + "/logs") else {
            throw ClientError.invalidURL
        }
        if let timestamp {
            components.queryItems = [URLQueryItem(name: "after", value: String(timestamp))]
        }
        guard let url = components.url else {
            throw ClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(connection.authKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        return request
    }

    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        if httpResponse.statusCode == 400,
           let data,
           let error = try? JSONDecoder().decode(ManagementErrorResponse.self, from: data),
           error.error == "logging to file disabled" {
            throw ProxyLogFailure.loggingDisabled
        }
        guard 200...299 ~= httpResponse.statusCode else {
            throw ClientError.httpError(httpResponse.statusCode)
        }
    }
}

private extension ManagementAPIClient {
    struct ManagementErrorResponse: Decodable {
        let error: String
    }

    struct LogsResponse: Decodable {
        let lines: [String]?
        let latestTimestamp: Int?

        enum CodingKeys: String, CodingKey {
            case lines
            case latestTimestamp = "latest-timestamp"
        }
    }

    enum ClientError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Invalid management API URL"
            case .invalidResponse:
                "Invalid management API response"
            case .httpError(let statusCode):
                "Management API returned HTTP \(statusCode)"
            }
        }
    }
}
