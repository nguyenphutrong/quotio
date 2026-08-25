import AppKit
import SwiftUI
import XCTest
@testable import Quotio

@MainActor
final class AppearanceModeTests: XCTestCase {
    func testSystemAppearanceInheritsFromTheMenuBar() {
        XCTAssertNil(AppearanceMode.system.appKitAppearance)
        XCTAssertNil(AppearanceMode.system.preferredColorScheme)
    }

    func testLightAppearanceUsesAquaAndLightColorScheme() throws {
        let appearance = try XCTUnwrap(AppearanceMode.light.appKitAppearance)

        XCTAssertEqual(appearance.name, .aqua)
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, .light)
    }

    func testDarkAppearanceUsesDarkAquaAndDarkColorScheme() throws {
        let appearance = try XCTUnwrap(AppearanceMode.dark.appKitAppearance)

        XCTAssertEqual(appearance.name, .darkAqua)
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, .dark)
    }
}
