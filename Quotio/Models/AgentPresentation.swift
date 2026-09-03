import Foundation
import QuotioDomain
import SwiftUI

extension CLIAgent {
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

extension ConfigurationSetup {
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

extension ConfigurationMode {
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

extension ConfigStorageOption {
    var icon: String {
        switch self {
        case .jsonOnly: return "doc.text"
        case .shellOnly: return "terminal"
        case .both: return "square.stack"
        }
    }
}

extension ModelSlot {
    var displayName: String {
        switch self {
        case .opus: return "Opus (High Intelligence)"
        case .sonnet: return "Sonnet (Balanced)"
        case .haiku: return "Haiku (Fast)"
        }
    }
}

extension CodexReasoningEffort {
    var displayName: String {
        if case .custom(let value) = self {
            return String.localizedStringWithFormat(
                "agents.reasoningEffort.custom".localizedStatic(),
                value
            )
        }
        return "agents.reasoningEffort.\(rawValue)".localizedStatic()
    }
}

extension AgentStatus {
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

extension AgentBackupFile {
    var displayName: String {
        DateFormatter.agentBackup.string(from: timestamp)
    }
}

private extension DateFormatter {
    static let agentBackup: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
