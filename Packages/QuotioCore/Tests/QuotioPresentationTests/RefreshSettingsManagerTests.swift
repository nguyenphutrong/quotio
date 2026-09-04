import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class RefreshSettingsManagerTests: XCTestCase {
    func testCadenceChangePersistsAndNotifiesEveryHandler() {
        let repository = RefreshPreferencesRepositoryFake()
        let manager = RefreshSettingsManager(repository: repository)
        var firstValues: [RefreshCadence] = []
        var secondValues: [RefreshCadence] = []
        manager.addCadenceChangeHandler { firstValues.append($0) }
        manager.addCadenceChangeHandler { secondValues.append($0) }

        manager.refreshCadence = .fiveMinutes

        XCTAssertEqual(repository.savedCadences, [.fiveMinutes])
        XCTAssertEqual(firstValues, [.fiveMinutes])
        XCTAssertEqual(secondValues, [.fiveMinutes])
    }
}

private final class RefreshPreferencesRepositoryFake: RefreshPreferencesRepository, @unchecked Sendable {
    private(set) var savedCadences: [RefreshCadence] = []

    func load() -> RefreshPreferences {
        RefreshPreferences(cadence: .tenMinutes)
    }

    func save(_ preferences: RefreshPreferences) {
        savedCadences.append(preferences.cadence)
    }
}
