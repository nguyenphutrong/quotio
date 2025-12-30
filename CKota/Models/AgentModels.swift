//
//  AgentModels.swift
//  CKota - CLI Agent Configuration Models
//

import Foundation
import SwiftUI

// MARK: - CLI Agent Types

enum CLIAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode = "claude-code"

    var id: String { rawValue }

    var displayName: String {
        "Claude Code"
    }

    var description: String {
        "Anthropic's official CLI for Claude models"
    }

    var configType: AgentConfigType {
        .both
    }

    var binaryNames: [String] {
        ["claude"]
    }

    var configPaths: [String] {
        ["~/.claude/settings.json"]
    }

    var docsURL: URL? {
        URL(string: "https://docs.anthropic.com/en/docs/claude-code")
    }

    var systemIcon: String {
        "brain.head.profile"
    }

    var color: Color {
        Color("D97706")
    }
}

// MARK: - Configuration Types

enum AgentConfigType: String, Codable, Sendable {
    case environment = "env"
    case file
    case both
}

// MARK: - Configuration Mode

enum ConfigurationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Manual"
        }
    }

    var icon: String {
        switch self {
        case .automatic: "gearshape.2"
        case .manual: "doc.text"
        }
    }

    var description: String {
        switch self {
        case .automatic: "Directly update config files and shell profile"
        case .manual: "View and copy configuration manually"
        }
    }
}

enum ConfigStorageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case jsonOnly = "json"
    case shellOnly = "shell"
    case both

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .jsonOnly: "doc.text"
        case .shellOnly: "terminal"
        case .both: "square.stack"
        }
    }
}

// MARK: - Model Slots

enum ModelSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: "Opus (High Intelligence)"
        case .sonnet: "Sonnet (Balanced)"
        case .haiku: "Haiku (Fast)"
        }
    }

    var envSuffix: String {
        rawValue.uppercased()
    }
}

// MARK: - Available Models for Routing

struct AvailableModel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let isDefault: Bool

    var displayName: String {
        name.split(separator: "-")
            .map(\.capitalized)
            .joined(separator: " ")
    }

    static let defaultModels: [ModelSlot: AvailableModel] = [
        .opus: AvailableModel(id: "opus", name: "gemini-claude-opus-4-5-thinking", provider: "openai", isDefault: true),
        .sonnet: AvailableModel(id: "sonnet", name: "gemini-claude-sonnet-4-5", provider: "openai", isDefault: true),
        .haiku: AvailableModel(id: "haiku", name: "gemini-3-flash-preview", provider: "openai", isDefault: true),
    ]

    static let allModels: [AvailableModel] = [
        AvailableModel(
            id: "gemini-claude-opus-4-5-thinking",
            name: "gemini-claude-opus-4-5-thinking",
            provider: "openai",
            isDefault: false
        ),
        AvailableModel(
            id: "gemini-claude-sonnet-4-5",
            name: "gemini-claude-sonnet-4-5",
            provider: "openai",
            isDefault: false
        ),
        AvailableModel(
            id: "gemini-claude-sonnet-4-5-thinking",
            name: "gemini-claude-sonnet-4-5-thinking",
            provider: "openai",
            isDefault: false
        ),
        AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "openai", isDefault: false),
        AvailableModel(
            id: "gemini-3-pro-image-preview",
            name: "gemini-3-pro-image-preview",
            provider: "openai",
            isDefault: false
        ),
        AvailableModel(
            id: "gemini-3-flash-preview",
            name: "gemini-3-flash-preview",
            provider: "openai",
            isDefault: false
        ),
        AvailableModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", provider: "openai", isDefault: false),
        AvailableModel(
            id: "gemini-2.5-flash-lite",
            name: "gemini-2.5-flash-lite",
            provider: "openai",
            isDefault: false
        ),
        AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2-codex", name: "gpt-5.2-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-max", name: "gpt-5.1-codex-max", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai", isDefault: false),
    ]
}

// MARK: - Agent Status

struct AgentStatus: Identifiable, Sendable {
    let agent: CLIAgent
    var installed: Bool
    var configured: Bool
    var binaryPath: String?
    var version: String?
    var lastConfigured: Date?

    var id: String { agent.id }

    var statusText: String {
        if !installed {
            "Not Installed"
        } else if configured {
            "Configured"
        } else {
            "Installed"
        }
    }

    var statusColor: Color {
        if !installed {
            .secondary
        } else if configured {
            .green
        } else {
            .orange
        }
    }
}

// MARK: - Agent Configuration

struct AgentConfiguration: Codable, Sendable {
    let agent: CLIAgent
    var modelSlots: [ModelSlot: String]
    var proxyURL: String
    var apiKey: String
    var useOAuth: Bool

    init(agent: CLIAgent, proxyURL: String, apiKey: String) {
        self.agent = agent
        self.proxyURL = proxyURL
        self.apiKey = apiKey
        self.useOAuth = false
        self.modelSlots = [
            .opus: AvailableModel.defaultModels[.opus]!.name,
            .sonnet: AvailableModel.defaultModels[.sonnet]!.name,
            .haiku: AvailableModel.defaultModels[.haiku]!.name,
        ]
    }
}

// MARK: - Raw Configuration Output (for Manual Mode)

struct RawConfigOutput: Sendable {
    let format: ConfigFormat
    let content: String
    let filename: String?
    let targetPath: String?
    let instructions: String

    enum ConfigFormat: String, Sendable {
        case shellExport = "shell"
        case toml
        case json
        case yaml
    }
}

// MARK: - Configuration Result

struct AgentConfigResult: Sendable {
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

enum ShellType: String, CaseIterable, Sendable {
    case zsh
    case bash
    case fish

    var profilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .zsh: return "\(home)/.zshrc"
        case .bash: return "\(home)/.bashrc"
        case .fish: return "\(home)/.config/fish/config.fish"
        }
    }

    var exportPrefix: String {
        switch self {
        case .zsh, .bash: "export"
        case .fish: "set -gx"
        }
    }
}

// MARK: - Connection Test Result

struct ConnectionTestResult: Sendable {
    let success: Bool
    let message: String
    let latencyMs: Int?
    let modelResponded: String?
}
