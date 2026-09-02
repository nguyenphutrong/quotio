import QuotioDomain
import XCTest
@testable import Quotio

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
}
