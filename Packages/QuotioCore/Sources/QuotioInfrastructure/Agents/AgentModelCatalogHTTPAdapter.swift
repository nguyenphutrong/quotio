import Foundation
import QuotioApplication
import QuotioDomain

public actor AgentModelCatalogHTTPAdapter: AgentModelCatalogRepository {
    public typealias AvailableCopilotModelIDs = @Sendable () async -> Set<String>
    public typealias Now = @Sendable () -> Date

    private let session: URLSession
    private let availableCopilotModelIDs: AvailableCopilotModelIDs
    private let now: Now

    public init(
        session: URLSession = URLSession(
            configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 10)
        ),
        availableCopilotModelIDs: @escaping AvailableCopilotModelIDs = { [] },
        now: @escaping Now = Date.init
    ) {
        self.session = session
        self.availableCopilotModelIDs = availableCopilotModelIDs
        self.now = now
    }

    public func fetchCatalog(configuration: AgentConfiguration) async throws -> [ModelCatalogEntry] {
        let request = try makeRequest(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try ModelCatalog.parse(data)
    }

    public func fetchAvailableModels(configuration: AgentConfiguration) async throws -> [AvailableModel] {
        let models = ModelCatalog.agentSetupModels(from: try await fetchCatalog(configuration: configuration))
        let copilotIDs = await availableCopilotModelIDs()
        guard !copilotIDs.isEmpty else { return models }
        return models.filter { model in
            model.provider != "github-copilot" || copilotIDs.contains(model.id)
        }
    }

    public func testConnection(
        agent _: CLIAgent,
        configuration: AgentConfiguration
    ) async -> ConnectionTestResult {
        let startTime = now()
        let request: URLRequest
        do {
            request = try makeRequest(configuration: configuration)
        } catch {
            return result(success: false, message: .invalidProxyURL)
        }

        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int(now().timeIntervalSince(startTime) * 1_000)
            guard let response = response as? HTTPURLResponse else {
                return result(success: false, message: .invalidResponse, latency: latency)
            }

            guard response.statusCode == 200 else {
                return result(
                    success: false,
                    message: errorDetail(in: data).map(AgentConnectionMessage.server)
                        ?? .httpStatus(response.statusCode),
                    latency: latency
                )
            }

            return result(
                success: true,
                message: .connected,
                latency: latency,
                model: firstModelID(in: data)
            )
        } catch {
            return result(success: false, message: .transport(details: error.localizedDescription))
        }
    }

    private func makeRequest(configuration: AgentConfiguration) throws -> URLRequest {
        guard let url = URL(string: "\(configuration.proxyURL)/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return request
    }

    private func firstModelID(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return nil }
        return models.first?["id"] as? String
    }

    private func errorDetail(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private func result(
        success: Bool,
        message: AgentConnectionMessage,
        latency: Int? = nil,
        model: String? = nil
    ) -> ConnectionTestResult {
        ConnectionTestResult(
            success: success,
            message: message,
            latencyMs: latency,
            modelResponded: model
        )
    }
}
