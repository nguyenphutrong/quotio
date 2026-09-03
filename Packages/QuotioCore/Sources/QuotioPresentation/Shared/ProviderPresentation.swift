import QuotioDomain
import SwiftUI

public extension QuotaProvider {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .qwen: "Qwen Code"
        case .iflow: "iFlow"
        case .antigravity: "Antigravity"
        case .vertex: "Vertex AI"
        case .kiro: "Kiro"
        case .copilot: "GitHub Copilot"
        case .cursor: "Cursor"
        case .factoryDroid: "Factory Droid"
        case .devin: "Devin"
        case .grok: "Grok"
        case .openRouter: "OpenRouter"
        case .amp: "Amp"
        case .trae: "Trae"
        case .glm: "Z.ai"
        case .warp: "Warp"
        case .clinePass: "ClinePass"
        }
    }

    var iconName: String {
        switch self {
        case .claude: "brain.head.profile"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .qwen: "cloud"
        case .iflow: "arrow.triangle.branch"
        case .antigravity: "wand.and.stars"
        case .vertex: "cube"
        case .kiro: "cloud.fill"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .factoryDroid: "cpu"
        case .devin: "bolt.horizontal.circle"
        case .grok: "xmark.circle"
        case .openRouter: "point.3.connected.trianglepath.dotted"
        case .amp: "bolt.fill"
        case .trae: "cursorarrow.rays"
        case .glm: "brain"
        case .warp: "terminal.fill"
        case .clinePass: "cpu"
        }
    }

    var logoAssetName: String {
        switch self {
        case .claude: "claude"
        case .codex: "openai"
        case .qwen: "qwen"
        case .iflow: "iflow"
        case .antigravity: "antigravity"
        case .vertex: "vertex"
        case .kiro: "kiro"
        case .copilot: "copilot"
        case .cursor: "cursor"
        case .factoryDroid: "factory-droid"
        case .devin: "devin"
        case .grok: "grok"
        case .openRouter: "openrouter"
        case .amp: "amp"
        case .trae: "trae"
        case .glm: "glm"
        case .warp: "warp"
        case .clinePass: "clinepass"
        }
    }

    var color: Color {
        switch self {
        case .claude: Color(hex: "D97706") ?? .orange
        case .codex: Color(hex: "10A37F") ?? .green
        case .qwen: Color(hex: "7C3AED") ?? .purple
        case .iflow: Color(hex: "06B6D4") ?? .cyan
        case .antigravity: Color(hex: "EC4899") ?? .pink
        case .vertex: Color(hex: "EA4335") ?? .red
        case .kiro: Color(hex: "9046FF") ?? .purple
        case .copilot: Color(hex: "238636") ?? .green
        case .cursor: Color(hex: "00D4AA") ?? .teal
        case .factoryDroid: Color(hex: "238636") ?? .green
        case .devin: Color(hex: "6C5CE7") ?? .purple
        case .grok: .primary
        case .openRouter: Color(hex: "6B5CFF") ?? .purple
        case .amp: Color(hex: "FF5543") ?? .red
        case .trae: Color(hex: "00B4D8") ?? .cyan
        case .glm: Color(hex: "3B82F6") ?? .blue
        case .warp: Color(hex: "01E5FF") ?? .cyan
        case .clinePass: Color(hex: "61A3FA") ?? .blue
        }
    }

    var oauthEndpoint: String {
        switch self {
        case .claude: "/anthropic-auth-url"
        case .codex: "/codex-auth-url"
        case .qwen: "/qwen-auth-url"
        case .iflow: "/iflow-auth-url"
        case .antigravity: "/antigravity-auth-url"
        default: ""
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .claude: "C"
        case .codex: "O"
        case .qwen: "Q"
        case .iflow: "F"
        case .antigravity: "A"
        case .vertex: "V"
        case .kiro: "K"
        case .copilot: "CP"
        case .cursor: "CR"
        case .factoryDroid: "FD"
        case .devin: "D"
        case .grok: "X"
        case .openRouter: "OR"
        case .amp: "AM"
        case .trae: "TR"
        case .glm: "G"
        case .warp: "W"
        case .clinePass: "CL"
        }
    }

    var menuBarIconAsset: String? {
        switch self {
        case .claude: "claude-menubar"
        case .codex: "openai-menubar"
        case .qwen: "qwen-menubar"
        case .copilot: "copilot-menubar"
        case .antigravity: "antigravity-menubar"
        case .kiro: "kiro-menubar"
        case .iflow: "iflow-menubar"
        case .vertex: "vertex-menubar"
        case .cursor: "cursor-menubar"
        case .amp: "amp-menubar"
        case .trae: "trae-menubar"
        case .glm: "glm-menubar"
        case .warp: "warp-menubar"
        case .clinePass: "clinepass-menubar"
        case .factoryDroid, .devin, .grok, .openRouter: nil
        }
    }
}

public extension AccountSource {
    var displayName: String { localizationKey.localizedStatic() }

    var localizationKey: String {
        switch self {
        case .quotioKeychain: "monitor.source.quotio"
        case .nativeCredential: "monitor.source.localLogin"
        case .legacyCLIProxy: "monitor.source.cliProxyFile"
        case .localIDE: "monitor.source.localIDE"
        case .apiKey: "monitor.source.apiKey"
        }
    }
}

public extension Account {
    var provider: QuotaProvider {
        guard let provider = QuotaProvider(rawValue: providerID.rawValue) else {
            preconditionFailure("Unsupported account provider: \(providerID.rawValue)")
        }
        return provider
    }
}

public extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255,
            green: Double((rgb & 0x00FF00) >> 8) / 255,
            blue: Double(rgb & 0x0000FF) / 255
        )
    }
}
