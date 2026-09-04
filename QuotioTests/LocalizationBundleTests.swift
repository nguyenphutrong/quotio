import QuotioApplication
import QuotioDomain
import XCTest
@testable import Quotio
@testable import QuotioPresentation

@MainActor
final class LocalizationBundleTests: XCTestCase {
    func testExecutableContainsAllSupportedLocalizationBundles() throws {
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                "Missing localization bundle for \(language.rawValue)"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))

            XCTAssertNotEqual(
                NSLocalizedString("nav.settings", bundle: bundle, comment: ""),
                "nav.settings",
                "Missing nav.settings in \(language.rawValue)"
            )
            for key in requiredLocalizationKeys {
                XCTAssertNotEqual(
                    NSLocalizedString(key, bundle: bundle, comment: ""),
                    key,
                    "Missing \(key) in \(language.rawValue)"
                )
            }
        }
    }

    func testCountMetricUnitsUseEnglishSingularAndPluralForms() {
        let languageManager = LanguageManager(repository: InMemoryLanguagePreferencesRepository(language: .english))
        defer { languageManager.setLanguage(storedLanguage) }

        withExtendedLifetime(languageManager) {
            XCTAssertEqual(QuotaMetricUnit.credits.format(1), "1 credit")
            XCTAssertEqual(QuotaMetricUnit.credits.format(2), "2 credits")
            XCTAssertEqual(QuotaMetricUnit.requests.format(1), "1 request")
            XCTAssertEqual(QuotaMetricUnit.requests.format(2), "2 requests")
            XCTAssertEqual(QuotaMetricUnit.searches.format(1), "1 search")
            XCTAssertEqual(QuotaMetricUnit.searches.format(2), "2 searches")
        }
    }

    func testLocalizedPlanAndEndpointLabelsUseSelectedLanguage() {
        let languageManager = LanguageManager(repository: InMemoryLanguagePreferencesRepository(language: .vietnamese))
        defer { languageManager.setLanguage(storedLanguage) }

        withExtendedLifetime(languageManager) {
            XCTAssertEqual(ProviderQuota(planType: "openrouter-free").planDisplayName, "Gói miễn phí")
            XCTAssertEqual(GLMEndpoint.zai.displayName, "Z.ai Toàn cầu")
        }
    }

    func testChangingLanguageUpdatesPresentationLocalization() {
        let languageManager = LanguageManager(repository: InMemoryLanguagePreferencesRepository(language: .english))
        defer { languageManager.setLanguage(storedLanguage) }

        XCTAssertEqual("nav.settings".localized(), "Settings")

        languageManager.setLanguage(.vietnamese)

        XCTAssertEqual("nav.settings".localized(), "Cài đặt")
    }

    func testAgentInstructionsResolveLocalizationOnlyInPresentation() {
        let languageManager = LanguageManager(repository: InMemoryLanguagePreferencesRepository(language: .english))
        defer { languageManager.setLanguage(storedLanguage) }

        XCTAssertEqual(
            AgentConfigurationInstruction.ampMergeSettings.localizedText,
            "Merge this property into ~/.config/amp/settings.json; do not replace the file"
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.invalidSyntax(line: 4, column: 9).localizedText,
            "Unexpected character at line 4, column 9."
        )
        XCTAssertEqual(
            AgentConfigurationFailure.updateSettingsFailed(details: "Disk full").localizedText,
            "Failed to update settings: Disk full"
        )

        languageManager.setLanguage(.vietnamese)

        XCTAssertEqual(
            AgentConfigurationInstruction.ampMergeSettings.localizedText,
            "Gộp thuộc tính này vào ~/.config/amp/settings.json; không thay thế tệp"
        )
        XCTAssertEqual(
            AgentConfigurationInstruction.openCodeConfigured(model: "gpt-5").localizedText,
            "Đã cập nhật cấu hình. Chạy 'opencode' và dùng /models để chọn mô hình (ví dụ: quotio/gpt-5)."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.invalidSyntax(line: 4, column: 9).localizedText,
            "Ký tự không hợp lệ tại dòng 4, cột 9."
        )
        XCTAssertEqual(
            AgentConfigurationFailure.updateSettingsFailed(details: "Disk full").localizedText,
            "Không thể cập nhật cài đặt: Disk full"
        )
        XCTAssertEqual(AgentConnectionMessage.connected.localizedText, "Kết nối thành công")
        XCTAssertEqual(
            agentConfigurationErrorMessage(ModelCatalogError.proxyUnavailable),
            "Proxy hiện không khả dụng."
        )
    }

    func testProxyCLIOAuthStatusesResolveLocalizationInPresentation() throws {
        let languageManager = LanguageManager(repository: InMemoryLanguagePreferencesRepository(language: .english))
        defer { languageManager.setLanguage(storedLanguage) }
        let providerID = AccountProviderID(rawValue: QuotaProvider.copilot.rawValue)

        var state = try XCTUnwrap(QuotaOAuthState(.awaitingUser(
            providerID: providerID,
            prompt: OAuthPrompt(status: .proxyCLI(.copilotBrowserOpened(deviceCode: "ABCD-1234")))
        )))
        XCTAssertEqual(
            state.error,
            "Browser opened for GitHub authentication.\n\nCode copied to clipboard:\n\nABCD-1234\n\nJust paste it in the browser!"
        )

        languageManager.setLanguage(.vietnamese)
        state = try XCTUnwrap(QuotaOAuthState(.awaitingUser(
            providerID: providerID,
            prompt: OAuthPrompt(status: .importingQuotas)
        )))
        XCTAssertEqual(state.error, "Đang nhập hạn mức...")
    }

    private var storedLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    private var requiredLocalizationKeys: [String] {
        [
            "agents.amp.configSuccess",
            "agents.amp.mergeAndSaveFiles",
            "agents.amp.mergeSecrets",
            "agents.amp.mergeSettings",
            "agents.amp.proxyRemoved",
            "agents.amp.removeProxyManually",
            "agents.amp.useEnvironmentVariables",
            "agents.claude.addShellExports",
            "agents.claude.chooseManualOption",
            "agents.claude.proxyRemoved",
            "agents.claude.removeProxyManually",
            "agents.claude.saveSettings",
            "agents.claude.settingsAndShellSaved",
            "agents.claude.settingsSaved",
            "agents.claude.shellExportsReady",
            "agents.codex.proxyRemoved",
            "agents.codex.applySuccess",
            "agents.codex.authJSONMergeKey",
            "agents.codex.mergeAndSaveFiles",
            "agents.codex.revertManualInstructions",
            "agents.codex.saveConfigTOML",
            "agents.connection.connected",
            "agents.connection.httpStatus",
            "agents.connection.invalidProxyURL",
            "agents.connection.invalidResponse",
            "agents.error.generateConfigFailed",
            "agents.error.updateConfigFailed",
            "agents.error.updateSettingsFailed",
            "agents.factoryDroid.configured",
            "agents.factoryDroid.proxyRemoved",
            "agents.factoryDroid.removeProxyManually",
            "agents.factoryDroid.saveConfig",
            "agents.factoryDroid.saveManualConfig",
            "agents.opencode.configured",
            "agents.opencode.mergeManualConfig",
            "agents.opencode.mergeProvider",
            "agents.opencode.notConfigured",
            "agents.opencode.parseError.duplicateKey",
            "agents.opencode.parseError.notObject",
            "agents.opencode.parseError.notUTF8",
            "agents.opencode.parseError.providerNotObject",
            "agents.opencode.parseError.syntax",
            "agents.opencode.parseError.unterminatedComment",
            "agents.opencode.parseError.unterminatedString",
            "agents.opencode.parseError.verification",
            "agents.opencode.parseFailed",
            "agents.opencode.proxyRemoved",
            "agents.opencode.removeProxyManually",
            "agents.service.adapterMismatch",
            "agents.service.missingAdapter",
            "agents.shellProfileUpdated",
            "agents.validation.invalidProxyURL",
            "agents.validation.missingAPIKey",
            "agents.validation.missingModel",
            "agents.validation.proxyUnavailable",
            "oauth.cli.authenticationCancelled",
            "oauth.cli.authenticationCompleted",
            "oauth.cli.browserOpened",
            "oauth.cli.copilotBrowserOpenedWithCode",
            "oauth.cli.copilotBrowserOpenedWithoutCode",
            "oauth.cli.failedToStart",
            "oauth.cli.importingQuotas",
        ]
    }
}

private final class InMemoryLanguagePreferencesRepository: LanguagePreferencesRepository, @unchecked Sendable {
    private var preferences: LanguagePreferences

    init(language: AppLanguage) {
        preferences = LanguagePreferences(language: language)
    }

    func load() -> LanguagePreferences {
        preferences
    }

    func save(_ preferences: LanguagePreferences) {
        self.preferences = preferences
    }
}
