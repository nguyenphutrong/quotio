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

    func testHostPlanNameIsPreservedWhileEndpointLabelsUseSelectedLanguage() {
        let languageManager = LanguageManager(repository: InMemoryLanguagePreferencesRepository(language: .vietnamese))
        defer { languageManager.setLanguage(storedLanguage) }

        withExtendedLifetime(languageManager) {
            XCTAssertEqual(ProviderQuota(planType: "Free Tier").planDisplayName, "Free Tier")
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
