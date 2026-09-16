import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class MenuBarSettingsManagerTests: XCTestCase {
    func testProviderSelectionPersistsWithoutRequestingFullMenuRebuild() {
        let repository = MenuBarPreferencesRepositoryFake()
        let manager = MenuBarSettingsManager(repository: repository)
        var changeCount = 0
        manager.setDidChangeHandler { _ in changeCount += 1 }

        manager.selectProvider(.claude)

        XCTAssertEqual(repository.savedPreferences.last?.selectedProvider, .claude)
        XCTAssertEqual(changeCount, 0)
    }
}

private final class MenuBarPreferencesRepositoryFake: MenuBarPreferencesRepository, @unchecked Sendable {
    private(set) var savedPreferences: [MenuBarPreferences] = []

    func load() -> MenuBarPreferences { MenuBarPreferences() }

    func save(_ preferences: MenuBarPreferences) {
        savedPreferences.append(preferences)
    }
}
