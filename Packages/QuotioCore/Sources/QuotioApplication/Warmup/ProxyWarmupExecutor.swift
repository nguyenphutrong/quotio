import Foundation
import QuotioDomain

public final class ProxyWarmupExecutor: WarmupExecuting, WarmupExecutionAvailabilityChecking,
    @unchecked Sendable
{
    private let managementAPI: @MainActor @Sendable () -> (any ProxyManagementAPI)?
    private let baseURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ]

    public init(
        managementAPI: @escaping @MainActor @Sendable () -> (any ProxyManagementAPI)?
    ) {
        self.managementAPI = managementAPI
    }

    public func isWarmupExecutionAvailable() async -> Bool {
        await managementAPI() != nil
    }

    public func fetchModels(authFileName: String) async throws -> [String] {
        guard let api = await managementAPI() else { return [] }
        return try await api.fetchAuthFileModels(name: authFileName).map(\.id)
    }

    public func warmup(authIndex: String, model: String) async throws {
        guard let api = await managementAPI() else { return }
        let payload = AntigravityWarmupRequest(
            project: "warmup-" + String(UUID().uuidString.prefix(5)).lowercased(),
            requestId: "agent-" + UUID().uuidString.lowercased(),
            userAgent: "antigravity",
            model: Self.mapModelAlias(model),
            request: AntigravityWarmupRequestBody(
                sessionId: "-" + String(UUID().uuidString.prefix(12)),
                contents: [
                    AntigravityWarmupContent(
                        role: "user",
                        parts: [AntigravityWarmupPart(text: ".")]
                    ),
                ],
                generationConfig: AntigravityWarmupGenerationConfiguration(maxOutputTokens: 1)
            )
        )
        guard let body = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            throw ProxyWarmupFailure.encodingFailed
        }

        var lastError: ProxyWarmupFailure?
        for baseURL in baseURLs {
            let response = try await api.apiCall(ProxyAPICall(
                authIndex: authIndex,
                method: "POST",
                url: baseURL + "/v1internal:generateContent",
                header: [
                    "Authorization": "Bearer $TOKEN$",
                    "Content-Type": "application/json",
                    "User-Agent": "antigravity/1.104.0",
                ],
                data: body
            ))
            if 200...299 ~= response.statusCode { return }
            lastError = .httpError(response.statusCode)
        }
        throw lastError ?? .invalidResponse
    }

    static func mapModelAlias(_ model: String) -> String {
        switch model.lowercased() {
        case "gemini-3-pro-preview": "gemini-3-pro-high"
        case "gemini-3-flash-preview": "gemini-3-flash"
        case "gemini-2.5-flash-preview": "gemini-2.5-flash"
        case "gemini-2.5-flash-lite-preview": "gemini-2.5-flash-lite"
        case "gemini-2.5-pro-preview": "gemini-2.5-pro"
        case "gemini-claude-sonnet-4-5": "claude-sonnet-4-5"
        case "gemini-claude-sonnet-4-5-thinking": "claude-sonnet-4-5-thinking"
        case "gemini-claude-opus-4-5-thinking": "claude-opus-4-5-thinking"
        case "gemini-claude-opus-4-6-thinking": "claude-opus-4-6-thinking"
        case "gemini-2.5-computer-use-preview-10-2025": "rev19-uic3-1p"
        case "gemini-3-pro-image-preview": "gemini-3-pro-image"
        default: model
        }
    }
}

public enum ProxyWarmupFailure: Error, Equatable, Sendable {
    case invalidResponse
    case encodingFailed
    case httpError(Int)
}

private struct AntigravityWarmupRequest: Encodable, Sendable {
    let project: String
    let requestId: String
    let userAgent: String
    let model: String
    let request: AntigravityWarmupRequestBody
}

private struct AntigravityWarmupRequestBody: Encodable, Sendable {
    let sessionId: String
    let contents: [AntigravityWarmupContent]
    let generationConfig: AntigravityWarmupGenerationConfiguration
}

private struct AntigravityWarmupContent: Encodable, Sendable {
    let role: String
    let parts: [AntigravityWarmupPart]
}

private struct AntigravityWarmupPart: Encodable, Sendable {
    let text: String
}

private struct AntigravityWarmupGenerationConfiguration: Encodable, Sendable {
    let maxOutputTokens: Int
}
