//
//  WarmupService.swift
//  Quotio
//

import Foundation

actor WarmupService {
    private let session: URLSession
    private let completionPath = "/v1/chat/completions"
    private let modelsPath = "/v1/models"
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }
    
    func warmup(baseURL: String, apiKey: String, model: String) async throws {
        guard let url = URL(string: baseURL + completionPath) else {
            throw WarmupError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(WarmupRequest(model: model))
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WarmupError.invalidResponse
        }
        guard 200...299 ~= httpResponse.statusCode else {
            throw WarmupError.httpError(httpResponse.statusCode)
        }
    }
    
    func fetchModels(baseURL: String, apiKey: String) async throws -> [WarmupModelInfo] {
        guard let url = URL(string: baseURL + modelsPath) else {
            throw WarmupError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WarmupError.invalidResponse
        }
        guard 200...299 ~= httpResponse.statusCode else {
            throw WarmupError.httpError(httpResponse.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(WarmupModelsResponse.self, from: data)
        return decoded.data
    }
}

nonisolated struct WarmupRequest: Codable, Sendable {
    let model: String
    let messages: [WarmupMessage]
    let maxTokens: Int
    let stream: Bool
    
    init(model: String) {
        self.model = model
        self.messages = [WarmupMessage(role: "user", content: ".")]
        self.maxTokens = 1
        self.stream = false
    }
    
    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
    }
}

nonisolated struct WarmupMessage: Codable, Sendable {
    let role: String
    let content: String
}

nonisolated struct WarmupModelsResponse: Codable, Sendable {
    let data: [WarmupModelInfo]
}

nonisolated struct WarmupModelInfo: Codable, Sendable {
    let id: String
    let ownedBy: String?
    let provider: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case provider
    }
}

nonisolated enum WarmupError: Error {
    case invalidURL
    case invalidResponse
    case httpError(Int)
}
