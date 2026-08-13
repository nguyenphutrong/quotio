//
//  AgentModels.swift
//  Quotio - CLI Agent Configuration Models
//

import Foundation
import SwiftUI

// MARK: - CLI Agent Types

nonisolated enum CLIAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codexCLI = "codex"
    case ampCLI = "amp"
    case openCode = "opencode"
    case factoryDroid = "factory-droid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .ampCLI: return "Amp CLI"
        case .openCode: return "OpenCode"
        case .factoryDroid: return "Factory Droid"
        }
    }

    var description: String {
        switch self {
        case .claudeCode: return "Anthropic's official CLI for Claude models"
        case .codexCLI: return "OpenAI's Codex CLI for GPT-5 models"
        case .ampCLI: return "Sourcegraph's Amp coding assistant"
        case .openCode: return "The open source AI coding agent"
        case .factoryDroid: return "Factory's AI coding agent"
        }
    }

    var configType: AgentConfigType {
        switch self {
        case .claudeCode: return .both
        case .codexCLI: return .file
        case .ampCLI: return .both
        case .openCode: return .file
        case .factoryDroid: return .file
        }
    }

    var binaryNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .codexCLI: return ["codex"]
        case .ampCLI: return ["amp"]
        case .openCode: return ["opencode", "oc"]
        case .factoryDroid: return ["droid", "factory-droid"]
        }
    }

    var configPaths: [String] {
        switch self {
        case .claudeCode: return ["~/.claude/settings.json"]
        case .codexCLI: return ["~/.codex/config.toml", "~/.codex/auth.json"]
        case .ampCLI: return ["~/.config/amp/settings.json", "~/.local/share/amp/secrets.json"]
        case .openCode: return ["~/.config/opencode/opencode.json"]
        case .factoryDroid: return ["~/.factory/config.json"]
        }
    }

    var docsURL: URL? {
        switch self {
        case .claudeCode: return URL(string: "https://docs.anthropic.com/en/docs/claude-code")
        case .codexCLI: return URL(string: "https://github.com/openai/codex")
        case .ampCLI: return URL(string: "https://ampcode.com/manual")
        case .openCode: return URL(string: "https://github.com/sst/opencode")
        case .factoryDroid: return URL(string: "https://docs.factory.ai/welcome")
        }
    }

    var systemIcon: String {
        switch self {
        case .claudeCode: return "brain.head.profile"
        case .codexCLI: return "chevron.left.forwardslash.chevron.right"
        case .ampCLI: return "bolt.fill"
        case .openCode: return "terminal"
        case .factoryDroid: return "cpu"
        }
    }

    var color: Color {
        switch self {
        case .claudeCode: return Color(hex: "D97706") ?? .orange
        case .codexCLI: return Color(hex: "10A37F") ?? .green
        case .ampCLI: return Color(hex: "FF5543") ?? .red
        case .openCode: return Color(hex: "8B5CF6") ?? .purple
        case .factoryDroid: return Color(hex: "238636") ?? .green
        }
    }
}

// MARK: - Configuration Types

nonisolated enum AgentConfigType: String, Codable, Sendable {
    case environment = "env"
    case file = "file"
    case both = "both"
}

// MARK: - Configuration Setup Mode

/// Determines whether to use proxy or default provider endpoints
nonisolated enum ConfigurationSetup: String, CaseIterable, Identifiable, Codable, Sendable {
    case proxy = "proxy"
    case defaultSetup = "default"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proxy: return "agents.setup.proxy".localizedStatic()
        case .defaultSetup: return "agents.setup.default".localizedStatic()
        }
    }

    var description: String {
        switch self {
        case .proxy: return "agents.setup.proxy.desc".localizedStatic()
        case .defaultSetup: return "agents.setup.default.desc".localizedStatic()
        }
    }

    var icon: String {
        switch self {
        case .proxy: return "arrow.triangle.branch"
        case .defaultSetup: return "arrow.right"
        }
    }
}

// MARK: - Configuration Mode

nonisolated enum ConfigurationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "automatic"
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        }
    }

    var icon: String {
        switch self {
        case .automatic: return "gearshape.2"
        case .manual: return "doc.text"
        }
    }

    var description: String {
        switch self {
        case .automatic: return "Directly update config files and shell profile"
        case .manual: return "View and copy configuration manually"
        }
    }
}

nonisolated enum ConfigStorageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case jsonOnly = "json"
    case shellOnly = "shell"
    case both = "both"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .jsonOnly: return "doc.text"
        case .shellOnly: return "terminal"
        case .both: return "square.stack"
        }
    }
}

// MARK: - Model Slots

nonisolated enum ModelSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Opus (High Intelligence)"
        case .sonnet: return "Sonnet (Balanced)"
        case .haiku: return "Haiku (Fast)"
        }
    }

    var envSuffix: String {
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
nonisolated enum CodexReasoningEffort: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable, Sendable {
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
    init?(rawValue: String) {
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

    var rawValue: String {
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
    static let allCases: [CodexReasoningEffort] = [
        .none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra
    ]

    var id: String { rawValue }

    /// Default effort, matching the value Quotio has historically written.
    static let defaultEffort: CodexReasoningEffort = .high

    var displayName: String {
        if case .custom(let value) = self {
            return String.localizedStringWithFormat(
                "agents.reasoningEffort.custom".localizedStatic(),
                value
            )
        }
        return "agents.reasoningEffort.\(rawValue)".localizedStatic()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CodexReasoningEffort(rawValue: rawValue) ?? .defaultEffort
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Available Models for Routing

nonisolated struct AvailableModel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let isDefault: Bool

    var displayName: String {
        name.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static let defaultModels: [ModelSlot: AvailableModel] = [
        .opus: AvailableModel(id: "opus", name: "gemini-claude-opus-4-6-thinking", provider: "openai", isDefault: true),
        .sonnet: AvailableModel(id: "sonnet", name: "gemini-claude-sonnet-4-5", provider: "openai", isDefault: true),
        .haiku: AvailableModel(id: "haiku", name: "gemini-3-flash-preview", provider: "openai", isDefault: true)
    ]

    static let allModels: [AvailableModel] = [
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

nonisolated struct AgentStatus: Identifiable, Sendable {
    let agent: CLIAgent
    var installed: Bool
    var configured: Bool
    var binaryPath: String?
    var version: String?
    var lastConfigured: Date?

    var id: String { agent.id }

    var statusText: String {
        if !installed {
            return "Not Installed"
        } else if configured {
            return "Configured"
        } else {
            return "Installed"
        }
    }

    var statusColor: Color {
        if !installed {
            return .secondary
        } else if configured {
            return .green
        } else {
            return .orange
        }
    }
}

// MARK: - Agent Configuration

nonisolated struct AgentConfiguration: Codable, Sendable {
    let agent: CLIAgent
    var modelSlots: [ModelSlot: String]
    var proxyURL: String
    var apiKey: String
    var useOAuth: Bool
    var setupMode: ConfigurationSetup
    /// Reasoning effort written to Codex CLI's `model_reasoning_effort`.
    /// Only used when `agent == .codexCLI`.
    var codexReasoningEffort: CodexReasoningEffort

    init(agent: CLIAgent, proxyURL: String, apiKey: String, setupMode: ConfigurationSetup = .proxy) {
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
    init(agent: CLIAgent, proxyURL: String, apiKey: String, setupMode: ConfigurationSetup = .proxy, savedModelSlots: [ModelSlot: String]) {
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
}

// MARK: - Raw Configuration Output (for Manual Mode)

nonisolated struct RawConfigOutput: Sendable {
    let format: ConfigFormat
    let content: String
    let filename: String?
    let targetPath: String?
    let instructions: String

    enum ConfigFormat: String, Sendable {
        case shellExport = "shell"
        case toml = "toml"
        case json = "json"
        case yaml = "yaml"
    }
}

// MARK: - Configuration Result

nonisolated struct AgentConfigResult: Sendable {
    let success: Bool
    let configType: AgentConfigType
    let mode: ConfigurationMode
    var configPath: String?
    var authPath: String?
    var shellConfig: String?
    var rawConfigs: [RawConfigOutput]
    var instructions: String
    var modelsConfigured: Int
    var error: String?
    var backupPath: String?

    static func success(
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

    static func failure(error: String) -> AgentConfigResult {
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

nonisolated enum ShellType: String, CaseIterable, Sendable {
    case zsh = "zsh"
    case bash = "bash"
    case fish = "fish"

    var profilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .zsh:
            if let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"], !zdotdir.isEmpty {
                return "\(zdotdir)/.zshrc"
            }
            let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
            let xdgZshDir = "\(xdgConfigHome)/zsh"
            if FileManager.default.fileExists(atPath: xdgZshDir) {
                return "\(xdgZshDir)/.zshrc"
            }
            return "\(home)/.zshrc"
        case .bash: return "\(home)/.bashrc"
        case .fish: return "\(home)/.config/fish/config.fish"
        }
    }

    var exportPrefix: String {
        switch self {
        case .zsh, .bash: return "export"
        case .fish: return "set -gx"
        }
    }
}

// MARK: - Connection Test Result

nonisolated struct ConnectionTestResult: Sendable {
    let success: Bool
    let message: String
    let latencyMs: Int?
    let modelResponded: String?
}
