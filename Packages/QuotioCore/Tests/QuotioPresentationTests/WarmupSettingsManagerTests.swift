import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class WarmupSettingsManagerTests: XCTestCase {
    func testSelectedModelChangePersistsAndNotifiesScheduleHandler() {
        let repository = WarmupPreferencesRepositoryFake()
        let manager = WarmupSettingsManager(repository: repository)
        var scheduleChangeCount = 0
        manager.onWarmupScheduleChanged = { scheduleChangeCount += 1 }

        manager.setSelectedModels(
            ["gemini-2.5-pro"],
            provider: .antigravity,
            accountKey: "person@example.com"
        )

        XCTAssertEqual(
            repository.savedPreferences.map(\.selectedModelsByAccount),
            [["antigravity::person@example.com": ["gemini-2.5-pro"]]]
        )
        XCTAssertEqual(scheduleChangeCount, 1)
    }
}

private final class WarmupPreferencesRepositoryFake: WarmupPreferencesRepository, @unchecked Sendable {
    private(set) var savedPreferences: [WarmupPreferences] = []

    func load() -> WarmupPreferences {
        WarmupPreferences()
    }

    func save(_ preferences: WarmupPreferences) {
        savedPreferences.append(preferences)
    }
}
