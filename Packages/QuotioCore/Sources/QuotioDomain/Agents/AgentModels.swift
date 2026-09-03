//
//  AgentModels.swift
//  Quotio - CLI Agent Configuration Models
//

import Foundation

// MARK: - CLI Agent Types

public enum CLIAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codexCLI = "codex"
    case ampCLI = "amp"
    case openCode = "opencode"
    case factoryDroid = "factory-droid"

    public var id: String { rawValue }

    public var configType: AgentConfigType {
        switch self {
        case .claudeCode: return .both
        case .codexCLI: return .file
        case .ampCLI: return .both
        case .openCode: return .file
        case .factoryDroid: return .file
        }
    }
}

// MARK: - Configuration Types

public enum AgentConfigType: String, Codable, Sendable {
    case environment = "env"
    case file = "file"
    case both = "both"
}

// MARK: - Configuration Setup Mode

/// Determines whether to use proxy or default provider endpoints
public enum ConfigurationSetup: String, CaseIterable, Identifiable, Codable, Sendable {
    case proxy = "proxy"
    case defaultSetup = "default"

    public var id: String { rawValue }
}

// MARK: - Configuration Mode

public enum ConfigurationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "automatic"
    case manual = "manual"

    public var id: String { rawValue }
}

public enum ConfigStorageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case jsonOnly = "json"
    case shellOnly = "shell"
    case both = "both"

    public var id: String { rawValue }
}

// MARK: - Model Slots

public enum ModelSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"

    public var id: String { rawValue }

    public var envSuffix: String {
        rawValue.uppercased()
    }
}

// MARK: - Codex Reasoning Effort

/// Reasoning effort accepted by Codex CLI's `model_reasoning_effort` key in
/// `~/.codex/config.toml`.
///
/// Codex treats this key as an **open** set. `ReasoningEffort` in
/// `codex-rs/protocol/src/openai_models.rs` names `none`, `minimal`, `low`,
/// `medium`, `high`, `xhigh`, `max` and `ultra`, and its hand-written
/// `FromStr` maps every other non-empty string to `ReasoningEffort::Custom`;
/// only the empty string is rejected. `custom` mirrors that escape hatch so a
/// value Quotio does not know is round-tripped verbatim instead of being
/// silently replaced.
public enum CodexReasoningEffort: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
    /// A valid Codex value Quotio does not have a named case for.
    /// Never produced for a value that maps to a named case — see `init(rawValue:)`.
    case custom(String)

    /// Fails only for the empty string, which Codex itself rejects with
    /// "reasoning_effort must not be empty".
    public init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xhigh
        case "max": self = .max
        case "ultra": self = .ultra
        case "": return nil
        default: self = .custom(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        case .ultra: return "ultra"
        case .custom(let value): return value
        }
    }

    /// The named values Quotio offers in the picker, ordered by effort.
    /// A `custom` value read from the user's config is offered alongside these.
    public static let allCases: [CodexReasoningEffort] = [
        .none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra
    ]

    public var id: String { rawValue }

    /// Default effort, matching the value Quotio has historically written.
    public static let defaultEffort: CodexReasoningEffort = .high

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CodexReasoningEffort(rawValue: rawValue) ?? .defaultEffort
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Available Models for Routing

public struct AvailableModel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let isDefault: Bool

    public init(id: String, name: String, provider: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.provider = provider
        self.isDefault = isDefault
    }

    public static let defaultModels: [ModelSlot: AvailableModel] = [
        .opus: AvailableModel(id: "opus", name: "gemini-claude-opus-4-6-thinking", provider: "openai", isDefault: true),
        .sonnet: AvailableModel(id: "sonnet", name: "gemini-claude-sonnet-4-5", provider: "openai", isDefault: true),
        .haiku: AvailableModel(id: "haiku", name: "gemini-3-flash-preview", provider: "openai", isDefault: true)
    ]

    public static let allModels: [AvailableModel] = [
        // Claude models
        AvailableModel(id: "gemini-claude-opus-4-6-thinking", name: "gemini-claude-opus-4-6-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-opus-4-5-thinking", name: "gemini-claude-opus-4-5-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5", name: "gemini-claude-sonnet-4-5", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5-thinking", name: "gemini-claude-sonnet-4-5-thinking", provider: "anthropic", isDefault: false),
        // Gemini models
        AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-3-pro-image-preview", name: "gemini-3-pro-image-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-3-flash-preview", name: "gemini-3-flash-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash-lite", name: "gemini-2.5-flash-lite", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-computer-use-preview-10-2025", name: "gemini-2.5-computer-use-preview-10-2025", provider: "google", isDefault: false),
        // GPT models
        AvailableModel(id: "gpt-5.3-codex", name: "gpt-5.3-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2-codex", name: "gpt-5.2-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1", name: "gpt-5.1", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-max", name: "gpt-5.1-codex-max", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-mini", name: "gpt-5.1-codex-mini", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5", name: "gpt-5", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex-mini", name: "gpt-5-codex-mini", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-oss-120b-medium", name: "gpt-oss-120b-medium", provider: "openai", isDefault: false),
    ]
}

// MARK: - Agent Status

public struct AgentStatus: Identifiable, Sendable {
    public let agent: CLIAgent
    public var installed: Bool
    public var configured: Bool
    public var binaryPath: String?
    public var version: String?
    public var lastConfigured: Date?

    public var id: String { agent.id }

    public init(
        agent: CLIAgent,
        installed: Bool,
        configured: Bool,
        binaryPath: String?,
        version: String?,
        lastConfigured: Date?
    ) {
        self.agent = agent
        self.installed = installed
        self.configured = configured
        self.binaryPath = binaryPath
        self.version = version
        self.lastConfigured = lastConfigured
    }
}

// MARK: - Agent Configuration

public struct AgentConfiguration: Codable, Sendable {
    public let agent: CLIAgent
    public var modelSlots: [ModelSlot: String]
    public var proxyURL: String
    public var apiKey: String
    public var useOAuth: Bool
    public var setupMode: ConfigurationSetup
    /// Reasoning effort written to Codex CLI's `model_reasoning_effort`.
    /// Only used when `agent == .codexCLI`.
    public var codexReasoningEffort: CodexReasoningEffort

    public init(agent: CLIAgent, proxyURL: String, apiKey: String, setupMode: ConfigurationSetup = .proxy) {
        self.agent = agent
        self.proxyURL = proxyURL
        self.apiKey = apiKey
        self.useOAuth = false
        self.setupMode = setupMode
        self.codexReasoningEffort = .defaultEffort
        self.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.allCases.compactMap { slot in
            AvailableModel.defaultModels[slot].map { (slot, $0.name) }
        })
    }

    /// Initialize with saved model slots (for restoring existing configuration)
    public init(agent: CLIAgent, proxyURL: String, apiKey: String, setupMode: ConfigurationSetup = .proxy, savedModelSlots: [ModelSlot: String]) {
        self.agent = agent
        self.proxyURL = proxyURL
        self.apiKey = apiKey
        self.useOAuth = false
        self.setupMode = setupMode
        self.codexReasoningEffort = .defaultEffort

        // Start with defaults, then overlay saved slots
        var slots = Dictionary(uniqueKeysWithValues: ModelSlot.allCases.compactMap { slot in
            AvailableModel.defaultModels[slot].map { (slot, $0.name) }
        })
        for (slot, model) in savedModelSlots {
            slots[slot] = model
        }
        self.modelSlots = slots
    }

    public func validate() throws {
        guard setupMode == .proxy else { return }

        guard let url = URL(string: proxyURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw AgentConfigurationValidationError.invalidProxyURL
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentConfigurationValidationError.missingAPIKey
        }

        let requiredSlots: [ModelSlot]
        switch agent {
        case .claudeCode:
            requiredSlots = ModelSlot.allCases
        case .codexCLI:
            requiredSlots = [.sonnet]
        case .ampCLI, .openCode, .factoryDroid:
            requiredSlots = []
        }
        if requiredSlots.contains(where: {
            modelSlots[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }) {
            throw AgentConfigurationValidationError.missingModel
        }
    }
}

public enum AgentConfigurationValidationError: LocalizedError, Equatable, Sendable {
    case invalidProxyURL
    case missingAPIKey
    case missingModel

    public var errorDescription: String? {
        switch self {
        case .invalidProxyURL:
            return "The proxy URL must be an absolute HTTP or HTTPS URL."
        case .missingAPIKey:
            return "An API key is required for proxy configuration."
        case .missingModel:
            return "A required model selection is missing."
        }
    }
}

public struct SavedAgentConfiguration: Sendable {
    public let baseURL: String?
    public let apiKey: String?
    public let modelSlots: [ModelSlot: String]
    public let isProxyConfigured: Bool
    public let backupFiles: [AgentBackupFile]
    public var reasoningEffort: CodexReasoningEffort?

    public init(
        baseURL: String?,
        apiKey: String?,
        modelSlots: [ModelSlot: String],
        isProxyConfigured: Bool,
        backupFiles: [AgentBackupFile],
        reasoningEffort: CodexReasoningEffort? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelSlots = modelSlots
        self.isProxyConfigured = isProxyConfigured
        self.backupFiles = backupFiles
        self.reasoningEffort = reasoningEffort
    }
}

public struct AgentBackupFile: Identifiable, Sendable {
    public let path: String
    public let timestamp: Date
    public let agent: CLIAgent

    public var id: String { path }

    public init(path: String, timestamp: Date, agent: CLIAgent) {
        self.path = path
        self.timestamp = timestamp
        self.agent = agent
    }
}

public struct AgentConfigurationRequest: Sendable {
    public let configuration: AgentConfiguration
    public let mode: ConfigurationMode
    public let storageOption: ConfigStorageOption
    public let availableModels: [AvailableModel]

    public init(
        configuration: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly,
        availableModels: [AvailableModel] = []
    ) {
        self.configuration = configuration
        self.mode = mode
        self.storageOption = storageOption
        self.availableModels = availableModels
    }
}

// MARK: - Raw Configuration Output (for Manual Mode)

public struct RawConfigOutput: Sendable {
    public let format: ConfigFormat
    public let content: String
    public let filename: String?
    public let targetPath: String?
    public let instructions: String

    public enum ConfigFormat: String, Sendable {
        case shellExport = "shell"
        case toml = "toml"
        case json = "json"
        case yaml = "yaml"
    }

    public init(
        format: ConfigFormat,
        content: String,
        filename: String?,
        targetPath: String?,
        instructions: String
    ) {
        self.format = format
        self.content = content
        self.filename = filename
        self.targetPath = targetPath
        self.instructions = instructions
    }
}

// MARK: - Configuration Result

public struct AgentConfigResult: Sendable {
    public let success: Bool
    public let configType: AgentConfigType
    public let mode: ConfigurationMode
    public var configPath: String?
    public var authPath: String?
    public var shellConfig: String?
    public var rawConfigs: [RawConfigOutput]
    public var instructions: String
    public var modelsConfigured: Int
    public var error: String?
    public var backupPath: String?

    public static func success(
        type: AgentConfigType,
        mode: ConfigurationMode,
        configPath: String? = nil,
        authPath: String? = nil,
        shellConfig: String? = nil,
        rawConfigs: [RawConfigOutput] = [],
        instructions: String,
        modelsConfigured: Int = 3,
        backupPath: String? = nil
    ) -> AgentConfigResult {
        AgentConfigResult(
            success: true,
            configType: type,
            mode: mode,
            configPath: configPath,
            authPath: authPath,
            shellConfig: shellConfig,
            rawConfigs: rawConfigs,
            instructions: instructions,
            modelsConfigured: modelsConfigured,
            error: nil,
            backupPath: backupPath
        )
    }

    public static func failure(error: String) -> AgentConfigResult {
        AgentConfigResult(
            success: false,
            configType: .environment,
            mode: .automatic,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "",
            modelsConfigured: 0,
            error: error,
            backupPath: nil
        )
    }
}

// MARK: - Shell Profile

public enum ShellType: String, CaseIterable, Sendable {
    case zsh = "zsh"
    case bash = "bash"
    case fish = "fish"

    public var exportPrefix: String {
        switch self {
        case .zsh, .bash: return "export"
        case .fish: return "set -gx"
        }
    }
}

// MARK: - Connection Test Result

public struct ConnectionTestResult: Sendable {
    public let success: Bool
    public let message: String
    public let latencyMs: Int?
    public let modelResponded: String?

    public init(success: Bool, message: String, latencyMs: Int?, modelResponded: String?) {
        self.success = success
        self.message = message
        self.latencyMs = latencyMs
        self.modelResponded = modelResponded
    }
}
