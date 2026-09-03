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

        languageManager.setLanguage(.vietnamese)

        XCTAssertEqual(
            AgentConfigurationInstruction.ampMergeSettings.localizedText,
            "Gộp thuộc tính này vào ~/.config/amp/settings.json; không thay thế tệp"
        )
    }

    private var storedLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .english
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
