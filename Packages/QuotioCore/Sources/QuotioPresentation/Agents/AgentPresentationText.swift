import Foundation
import QuotioApplication
import QuotioDomain

public extension AgentConfigurationInstruction {
    @MainActor
    var localizedText: String {
        switch self {
        case .ampRemoveProxyManually:
            "Remove 'amp.url' from ~/.config/amp/settings.json"
        case .ampProxyRemoved:
            "Removed proxy URL. Amp CLI will now use its default endpoint."
        case .ampMergeSettings:
            "agents.amp.mergeSettings".localized()
        case .ampMergeSecrets:
            "agents.amp.mergeSecrets".localized()
        case .ampUseEnvironmentVariables:
            "agents.amp.useEnvironmentVariables".localized()
        case .ampConfigured:
            "agents.amp.configSuccess".localized()
        case .ampMergeAndSaveFiles:
            "agents.amp.mergeAndSaveFiles".localized()

        case .codexRemoveProxyManually:
            "agents.codex.revertManualInstructions".localized()
        case .codexProxyRemoved:
            "Removed CLIProxyAPI configuration. Codex CLI will now use OpenAI API directly."
        case .codexSaveConfig:
            "agents.codex.saveConfigTOML".localized()
        case .codexMergeAuthKey:
            "agents.codex.authJSONMergeKey".localized()
        case .codexConfigured:
            "agents.codex.applySuccess".localized()
        case .codexMergeAndSaveFiles:
            "agents.codex.mergeAndSaveFiles".localized()

        case .claudeRemoveProxyManually:
            """
            To revert to default, remove these environment variables from ~/.claude/settings.json:
            - ANTHROPIC_BASE_URL
            - ANTHROPIC_AUTH_TOKEN
            - ANTHROPIC_DEFAULT_OPUS_MODEL
            - ANTHROPIC_DEFAULT_SONNET_MODEL
            - ANTHROPIC_DEFAULT_HAIKU_MODEL
            """
        case .claudeProxyRemoved:
            "Removed Quotio proxy configuration. Claude Code will now use its default Anthropic API endpoint."
        case .claudeSaveSettings:
            "Option 1: Save as ~/.claude/settings.json"
        case .claudeAddShellExports:
            "Option 2: Add to your shell profile"
        case .claudeSettingsSaved:
            "Configuration saved to ~/.claude/settings.json"
        case .claudeShellExportsReady:
            "Shell exports ready. Add to your shell profile to complete setup."
        case .claudeSettingsAndShellSaved:
            "Configuration saved to ~/.claude/settings.json and shell profile updated."
        case .claudeChooseManualOption:
            "Choose one option: save settings.json OR add shell exports to your profile:"

        case .factoryDroidRemoveProxyManually:
            "Remove custom_models with localhost base_url from ~/.factory/config.json"
        case .factoryDroidProxyRemoved:
            "Removed proxy models. Factory Droid will use its default configurations."
        case .factoryDroidSaveConfig:
            "Save this as ~/.factory/config.json"
        case .factoryDroidConfigured:
            "Configuration saved. Run 'droid' or 'factory' to start using Factory Droid."
        case .factoryDroidSaveManualConfig:
            "Copy the configuration below and save it as ~/.factory/config.json:"

        case .openCodeRemoveProxyManually:
            "Remove 'provider.quotio' section from ~/.config/opencode/opencode.json"
        case .openCodeNotConfigured:
            "agents.opencode.notConfigured".localized()
        case .openCodeProxyRemoved:
            "Removed Quotio provider. OpenCode will use its default providers."
        case .openCodeMergeProvider:
            "Merge provider.quotio into ~/.config/opencode/opencode.json"
        case .openCodeConfigured(let model):
            "Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/\(model))."
        case .openCodeMergeManualConfig:
            "Merge provider.quotio section into your existing ~/.config/opencode/opencode.json:"

        case .shellProfileUpdated(let path):
            "Added to \(path). Restart your terminal for changes to take effect."
        }
    }
}

public extension AgentConfigurationFailure {
    @MainActor
    var localizedText: String {
        switch self {
        case .updateSettingsFailed(let details):
            "Failed to update settings: \(details)"
        case .updateConfigFailed(let details):
            "Failed to update config: \(details)"
        case .generateConfigFailed(let details):
            "Failed to generate config: \(details)"
        case .openCodeConfigInvalid(let path, let issue):
            String(format: "agents.opencode.parseFailed".localized(), path, issue.localizedText)
        case .operationFailed(let details):
            details
        }
    }
}

public extension OpenCodeConfigIssue {
    @MainActor
    var localizedText: String {
        switch self {
        case .notUTF8:
            "The OpenCode configuration is not valid UTF-8."
        case .unterminatedBlockComment:
            "The OpenCode configuration contains an unterminated block comment."
        case .unterminatedString:
            "The OpenCode configuration contains an unterminated string."
        case .invalidSyntax(let line, let column):
            "The OpenCode configuration has invalid syntax at line \(line), column \(column)."
        case .rootNotObject:
            "The OpenCode configuration root must be a JSON object."
        case .duplicateKey(let key):
            "The OpenCode configuration contains the duplicate key '\(key)'."
        case .providerNotObject:
            "The OpenCode provider value must be a JSON object."
        case .verificationFailed:
            "The updated OpenCode configuration could not be verified."
        }
    }
}

public extension AgentConnectionMessage {
    var localizedText: String {
        switch self {
        case .connected:
            "Connected successfully"
        case .invalidProxyURL:
            "Invalid proxy URL"
        case .invalidResponse:
            "Invalid response"
        case .httpStatus(let statusCode):
            "HTTP \(statusCode)"
        case .server(let details), .transport(let details):
            details
        }
    }
}

@MainActor
func agentConfigurationErrorMessage(_ error: Error) -> String {
    switch error {
    case ModelCatalogError.proxyUnavailable:
        "The proxy is not available."
    case AgentConfigurationValidationError.invalidProxyURL:
        "The proxy URL must be an absolute HTTP or HTTPS URL."
    case AgentConfigurationValidationError.missingAPIKey:
        "An API key is required for proxy configuration."
    case AgentConfigurationValidationError.missingModel:
        "A required model selection is missing."
    case AgentConfigurationServiceError.missingAdapter(let agent):
        "No configuration adapter is registered for \(agent.rawValue)."
    case AgentConfigurationServiceError.adapterMismatch(let expected, let actual):
        "The \(expected.rawValue) adapter cannot configure \(actual.rawValue)."
    default:
        error.localizedDescription
    }
}
