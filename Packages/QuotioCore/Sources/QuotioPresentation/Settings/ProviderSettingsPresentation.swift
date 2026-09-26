import QuotioApplication
import QuotioDomain
import SwiftUI

@MainActor
extension ConnectionState {
    var title: String {
        let key: String = switch self {
        case .connected: "settings.connection.connected"
        case .permissionRequired: "settings.connection.permission"
        case .reauthenticationRequired: "settings.connection.reauthenticate"
        case .notConnected: "settings.connection.none"
        case .disabled: "settings.connection.disabled"
        }
        return key.localizedStatic()
    }
    var symbol: String {
        switch self {
        case .connected: "checkmark.circle"
        case .permissionRequired: "lock"
        case .reauthenticationRequired: "exclamationmark.triangle"
        case .notConnected: "circle.dashed"
        case .disabled: "pause.circle"
        }
    }
    var color: Color {
        switch self {
        case .connected: .green
        case .permissionRequired, .reauthenticationRequired: .orange
        case .notConnected, .disabled: .secondary
        }
    }
}

@MainActor
extension QuotaRefreshState {
    var title: String {
        let key: String = switch self {
        case .notLoaded: "settings.quota.notLoaded"
        case .fresh: "settings.quota.fresh"
        case .refreshing: "status.refreshing"
        case .stale: "settings.quota.stale"
        case .failed: "settings.quota.failed"
        }
        return key.localizedStatic()
    }
}

@MainActor
extension AccountLoginSource {
    var title: String {
        let key: String? = switch credentialReference {
        case "claude_native": "connections.source.claude"
        case "codex_native": "connections.source.codex"
        case "factory_native": "connections.source.factory"
        case "antigravity_native": "connections.source.antigravity"
        case "kiro_native": "connections.source.kiro"
        case "amp_native": "connections.source.amp"
        default: nil
        }
        return key?.localizedStatic() ?? source.displayName
    }

    var locationLabel: String {
        switch (credentialReference, location) {
        case ("claude_native", "code_keychain"): return "Keychain · Claude Code-credentials"
        case ("claude_native", "code_file"): return "~/.claude/.credentials.json"
        case ("factory_native", "v2_file"): return "~/.factory/auth.v2.file"
        case ("factory_native", "v2_login_keychain"), ("factory_native", "v2_keyring"), ("factory_native", "legacy"):
            return "Keychain · Factory CLI"
        case ("antigravity_native", "gemini_keychain"): return "Keychain · gemini / antigravity"
        case ("codex_native", "default"): return "~/.codex/auth.json"
        case ("codex_native", "config"): return "~/.config/codex/auth.json"
        default:
            if source == .quotioKeychain || source == .apiKey { return "settings.sources.quotioKeychain".localizedStatic() }
            return "settings.sources.locationUnknown".localizedStatic()
        }
    }
}

@MainActor
extension NativeSourcePermission {
    var keychainItemName: String {
        switch kind {
        case "claude_native": "Claude Code-credentials"
        case "copilot_native": "gh:github.com"
        case "factory_native": "Factory CLI"
        case "antigravity_native": "gemini / antigravity"
        default: kind
        }
    }
}

@MainActor
extension NativeSourceAuthorizationFailure {
    var message: String {
        let key: String = switch self {
        case .quotioVault: "settings.permissionFailure.vault"
        case .nativeKeychain: "settings.permissionFailure.source"
        case .nativeLogin: "settings.permissionFailure.login"
        case .invalidCredential: "settings.permissionFailure.invalid"
        case .timeout: "settings.permissionFailure.timeout"
        case .unknown: "settings.permissionFailure.unknown"
        }
        return key.localizedStatic()
    }
}
