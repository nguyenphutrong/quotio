//
//  WarmupService.swift
//  Quotio
//

import Foundation

actor WarmupService {
    private let antigravityBaseURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]

    func warmup(managementClient: ManagementAPIClient, authIndex: String, model: String) async throws {
        let upstreamModel = mapAntigravityModelAlias(model)
        let payload = AntigravityWarmupRequest(
            project: "warmup-" + String(UUID().uuidString.prefix(5)).lowercased(),
            requestId: "agent-" + UUID().uuidString.lowercased(),
            userAgent: "antigravity",
            model: upstreamModel,
            request: AntigravityWarmupRequestBody(
                sessionId: "-" + String(UUID().uuidString.prefix(12)),
                contents: [
                    AntigravityWarmupContent(
                        role: "user",
                        parts: [AntigravityWarmupPart(text: ".")]
                    )
                ],
                generationConfig: AntigravityWarmupGenerationConfig(maxOutputTokens: 1)
            )
        )

        guard let body = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            throw WarmupError.encodingFailed
        }

        var lastError: WarmupError?
        for baseURL in antigravityBaseURLs {
            let response = try await managementClient.apiCall(APICallRequest(
                authIndex: authIndex,
                method: "POST",
                url: baseURL + "/v1internal:generateContent",
                header: [
                    "Authorization": "Bearer $TOKEN$",
                    "Content-Type": "application/json",
                    "User-Agent": "antigravity/1.104.0"
                ],
                data: body
            ))

            if 200...299 ~= response.statusCode {
                return
            }
            lastError = WarmupError.httpError(response.statusCode, response.body)
        }

        if let lastError {
            throw lastError
        }
        throw WarmupError.invalidResponse
    }

    private func mapAntigravityModelAlias(_ model: String) -> String {
        switch model.lowercased() {
        case "gemini-3-pro-preview":
            return "gemini-3-pro-high"
        case "gemini-3-flash-preview":
            return "gemini-3-flash"
        case "gemini-2.5-flash-preview":
            return "gemini-2.5-flash"
        case "gemini-2.5-flash-lite-preview":
            return "gemini-2.5-flash-lite"
        case "gemini-2.5-pro-preview":
            return "gemini-2.5-pro"
        case "gemini-claude-sonnet-4-5":
            return "claude-sonnet-4-5"
        case "gemini-claude-sonnet-4-5-thinking":
            return "claude-sonnet-4-5-thinking"
        case "gemini-claude-opus-4-5-thinking":
            return "claude-opus-4-5-thinking"
        case "gemini-claude-opus-4-6-thinking":
            return "claude-opus-4-6-thinking"
        case "gemini-2.5-computer-use-preview-10-2025":
            return "rev19-uic3-1p"
        case "gemini-3-pro-image-preview":
            return "gemini-3-pro-image"
        default:
            return model
        }
    }

    func fetchModels(managementClient: ManagementAPIClient, authFileName: String) async throws -> [WarmupModelInfo] {
        let models = try await managementClient.fetchAuthFileModels(name: authFileName)
        return models.map { model in
            WarmupModelInfo(
                id: model.id,
                ownedBy: model.ownedBy,
                provider: model.type
            )
        }
    }
}

nonisolated struct AntigravityWarmupRequest: Codable, Sendable {
    let project: String
    let requestId: String
    let userAgent: String
    let model: String
    let request: AntigravityWarmupRequestBody

    enum CodingKeys: String, CodingKey {
        case project, model, request
        case requestId = "requestId"
        case userAgent = "userAgent"
    }
}

nonisolated struct AntigravityWarmupRequestBody: Codable, Sendable {
    let sessionId: String
    let contents: [AntigravityWarmupContent]
    let generationConfig: AntigravityWarmupGenerationConfig

    enum CodingKeys: String, CodingKey {
        case contents, generationConfig
        case sessionId = "sessionId"
    }
}

nonisolated struct AntigravityWarmupContent: Codable, Sendable {
    let role: String
    let parts: [AntigravityWarmupPart]
}

nonisolated struct AntigravityWarmupPart: Codable, Sendable {
    let text: String
}

nonisolated struct AntigravityWarmupGenerationConfig: Codable, Sendable {
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case maxOutputTokens = "maxOutputTokens"
    }
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
    case encodingFailed
    case httpError(Int, String?)
}

extension WarmupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid warmup URL"
        case .invalidResponse:
            return "Invalid warmup response"
        case .encodingFailed:
            return "Failed to encode warmup payload"
        case .httpError(let status, let body):
            let snippet = body?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240)
            if let snippet, !snippet.isEmpty {
                return "Warmup HTTP \(status): \(snippet)"
            }
            return "Warmup HTTP \(status)"
        }
    }
}
