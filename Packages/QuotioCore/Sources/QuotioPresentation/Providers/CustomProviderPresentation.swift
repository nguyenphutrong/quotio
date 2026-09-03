import Foundation
import QuotioApplication
import QuotioDomain
import SwiftUI

public extension CustomProviderType {
    var displayName: String {
        switch self {
        case .openaiCompatibility: "OpenAI Compatible"
        case .claudeCompatibility: "Claude Compatible"
        case .geminiCompatibility: "Gemini Compatible"
        case .codexCompatibility: "Codex Compatible"
        case .glmCompatibility: "Z.ai / GLM"
        case .clinePass: "ClinePass"
        }
    }

    @MainActor
    var localizedDisplayName: String {
        switch self {
        case .openaiCompatibility: "customProviders.type.openai".localized()
        case .claudeCompatibility: "customProviders.type.claude".localized()
        case .geminiCompatibility: "customProviders.type.gemini".localized()
        case .codexCompatibility: "customProviders.type.codex".localized()
        case .glmCompatibility: "customProviders.type.glm".localized()
        case .clinePass: "customProviders.type.clinepass".localized()
        }
    }

    var description: String {
        switch self {
        case .openaiCompatibility:
            "OpenRouter, Ollama, LM Studio, vLLM, or any OpenAI-compatible API"
        case .claudeCompatibility:
            "Anthropic API or Claude-compatible providers"
        case .geminiCompatibility:
            "Google Gemini API or Gemini-compatible providers"
        case .codexCompatibility:
            "Custom Codex-compatible endpoints"
        case .glmCompatibility:
            "Z.ai GLM Coding Plan API"
        case .clinePass:
            "ClinePass subscription with OpenAI-compatible routing"
        }
    }

    @MainActor
    var localizedDescription: String {
        switch self {
        case .openaiCompatibility: "customProviders.type.openai.desc".localized()
        case .claudeCompatibility: "customProviders.type.claude.desc".localized()
        case .geminiCompatibility: "customProviders.type.gemini.desc".localized()
        case .codexCompatibility: "customProviders.type.codex.desc".localized()
        case .glmCompatibility: "customProviders.type.glm.desc".localized()
        case .clinePass: "customProviders.type.clinepass.desc".localized()
        }
    }

    var providerIconName: String {
        switch self {
        case .openaiCompatibility, .codexCompatibility: "openai"
        case .claudeCompatibility: "claude"
        case .geminiCompatibility: "gemini"
        case .glmCompatibility: "glm"
        case .clinePass: "clinepass"
        }
    }

    var menuBarIconName: String {
        switch self {
        case .openaiCompatibility, .codexCompatibility: "openai-menubar"
        case .claudeCompatibility: "claude-menubar"
        case .geminiCompatibility: "gemini-menubar"
        case .glmCompatibility: "glm-menubar"
        case .clinePass: "clinepass-menubar"
        }
    }

    var color: Color {
        switch self {
        case .openaiCompatibility, .codexCompatibility: Color(hex: "10A37F") ?? .green
        case .claudeCompatibility: Color(hex: "D97706") ?? .orange
        case .geminiCompatibility: Color(hex: "4285F4") ?? .blue
        case .glmCompatibility: Color(hex: "3B82F6") ?? .blue
        case .clinePass: Color(hex: "61A3FA") ?? .blue
        }
    }
}

public extension CustomHeader {
    static func validationErrors(in headers: [CustomHeader]) -> [String] {
        validationIssues(in: headers).map { issue in
            switch issue {
            case .invalidHeaderName: "customProviders.error.headerNameInvalid".localizedStatic()
            case .invalidHeaderValue: "customProviders.error.headerValueInvalid".localizedStatic()
            case .duplicateHeaderName: "customProviders.error.headerNameDuplicate".localizedStatic()
            default: ""
            }
        }
    }
}

public extension CustomProviderValidationIssue {
    func localizedMessage(providerType: CustomProviderType) -> String {
        switch self {
        case .nameRequired:
            "Provider name is required"
        case .duplicateName:
            "A provider with this name already exists"
        case .baseURLRequired:
            "Base URL is required for \(providerType.displayName)"
        case .invalidBaseURL:
            "Invalid base URL format"
        case .apiKeyRequired:
            "At least one API key is required"
        case .emptyAPIKey(let index):
            "API key #\(index) is empty"
        case .clinePassSingleKey:
            "clinepass.error.singleKey".localizedStatic()
        case .clinePassModelsRequired:
            "clinepass.error.modelsRequired".localizedStatic()
        case .invalidHeaderName:
            "customProviders.error.headerNameInvalid".localizedStatic()
        case .invalidHeaderValue:
            "customProviders.error.headerValueInvalid".localizedStatic()
        case .duplicateHeaderName:
            "customProviders.error.headerNameDuplicate".localizedStatic()
        }
    }
}

public extension CustomProvider {
    func validate() -> [String] {
        validationIssues().map {
            $0.localizedMessage(providerType: type)
        }
    }

    var isValid: Bool { validationIssues().isEmpty }
}
