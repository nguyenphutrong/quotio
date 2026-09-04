import Foundation
import QuotioApplication
import QuotioDomain

public extension AgentConfigurationInstruction {
    @MainActor
    var localizedText: String {
        switch self {
        case .ampRemoveProxyManually:
            "agents.amp.removeProxyManually".localized()
        case .ampProxyRemoved:
            "agents.amp.proxyRemoved".localized()
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
            "agents.codex.proxyRemoved".localized()
        case .codexSaveConfig:
            "agents.codex.saveConfigTOML".localized()
        case .codexMergeAuthKey:
            "agents.codex.authJSONMergeKey".localized()
        case .codexConfigured:
            "agents.codex.applySuccess".localized()
        case .codexMergeAndSaveFiles:
            "agents.codex.mergeAndSaveFiles".localized()

        case .claudeRemoveProxyManually:
            "agents.claude.removeProxyManually".localized()
        case .claudeProxyRemoved:
            "agents.claude.proxyRemoved".localized()
        case .claudeSaveSettings:
            "agents.claude.saveSettings".localized()
        case .claudeAddShellExports:
            "agents.claude.addShellExports".localized()
        case .claudeSettingsSaved:
            "agents.claude.settingsSaved".localized()
        case .claudeShellExportsReady:
            "agents.claude.shellExportsReady".localized()
        case .claudeSettingsAndShellSaved:
            "agents.claude.settingsAndShellSaved".localized()
        case .claudeChooseManualOption:
            "agents.claude.chooseManualOption".localized()

        case .factoryDroidRemoveProxyManually:
            "agents.factoryDroid.removeProxyManually".localized()
        case .factoryDroidProxyRemoved:
            "agents.factoryDroid.proxyRemoved".localized()
        case .factoryDroidSaveConfig:
            "agents.factoryDroid.saveConfig".localized()
        case .factoryDroidConfigured:
            "agents.factoryDroid.configured".localized()
        case .factoryDroidSaveManualConfig:
            "agents.factoryDroid.saveManualConfig".localized()

        case .openCodeRemoveProxyManually:
            "agents.opencode.removeProxyManually".localized()
        case .openCodeNotConfigured:
            "agents.opencode.notConfigured".localized()
        case .openCodeProxyRemoved:
            "agents.opencode.proxyRemoved".localized()
        case .openCodeMergeProvider:
            "agents.opencode.mergeProvider".localized()
        case .openCodeConfigured(let model):
            String(format: "agents.opencode.configured".localized(), model)
        case .openCodeMergeManualConfig:
            "agents.opencode.mergeManualConfig".localized()

        case .shellProfileUpdated(let path):
            String(format: "agents.shellProfileUpdated".localized(), path)
        }
    }
}

public extension AgentConfigurationFailure {
    @MainActor
    var localizedText: String {
        switch self {
        case .updateSettingsFailed(let details):
            String(format: "agents.error.updateSettingsFailed".localized(), details)
        case .updateConfigFailed(let details):
            String(format: "agents.error.updateConfigFailed".localized(), details)
        case .generateConfigFailed(let details):
            String(format: "agents.error.generateConfigFailed".localized(), details)
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
            "agents.opencode.parseError.notUTF8".localized()
        case .unterminatedBlockComment:
            "agents.opencode.parseError.unterminatedComment".localized()
        case .unterminatedString:
            "agents.opencode.parseError.unterminatedString".localized()
        case .invalidSyntax(let line, let column):
            String(
                format: "agents.opencode.parseError.syntax".localized(),
                String(line),
                String(column)
            )
        case .rootNotObject:
            "agents.opencode.parseError.notObject".localized()
        case .duplicateKey(let key):
            String(format: "agents.opencode.parseError.duplicateKey".localized(), key)
        case .providerNotObject:
            "agents.opencode.parseError.providerNotObject".localized()
        case .verificationFailed:
            "agents.opencode.parseError.verification".localized()
        }
    }
}

public extension AgentConnectionMessage {
    @MainActor
    var localizedText: String {
        switch self {
        case .connected:
            "agents.connection.connected".localized()
        case .invalidProxyURL:
            "agents.connection.invalidProxyURL".localized()
        case .invalidResponse:
            "agents.connection.invalidResponse".localized()
        case .httpStatus(let statusCode):
            String(format: "agents.connection.httpStatus".localized(), Int64(statusCode))
        case .server(let details), .transport(let details):
            details
        }
    }
}

@MainActor
func agentConfigurationErrorMessage(_ error: Error) -> String {
    switch error {
    case ModelCatalogError.proxyUnavailable:
        "agents.validation.proxyUnavailable".localized()
    case AgentConfigurationValidationError.invalidProxyURL:
        "agents.validation.invalidProxyURL".localized()
    case AgentConfigurationValidationError.missingAPIKey:
        "agents.validation.missingAPIKey".localized()
    case AgentConfigurationValidationError.missingModel:
        "agents.validation.missingModel".localized()
    case AgentConfigurationServiceError.missingAdapter(let agent):
        String(format: "agents.service.missingAdapter".localized(), agent.rawValue)
    case AgentConfigurationServiceError.adapterMismatch(let expected, let actual):
        String(
            format: "agents.service.adapterMismatch".localized(),
            expected.rawValue,
            actual.rawValue
        )
    default:
        error.localizedDescription
    }
}
