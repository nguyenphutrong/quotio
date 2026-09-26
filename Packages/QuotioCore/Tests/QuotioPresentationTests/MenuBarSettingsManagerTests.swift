import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class MenuBarSettingsManagerTests: XCTestCase {
    func testPinAndUnpinRespectCapacityAndManualSelection() {
        let manager = MenuBarSettingsManager(repository: MenuBarPreferencesRepositoryFake())
        manager.menuBarMaxItems = 1
        let first = MenuBarQuotaItem(provider: "claude", accountKey: "personal")
        let second = MenuBarQuotaItem(provider: "codex", accountKey: "work")
        manager.showMenuBarIcon = false
        manager.showQuotaInMenuBar = false

        manager.toggleItem(first)
        XCTAssertEqual(manager.currentItems, [first])
        XCTAssertTrue(manager.showMenuBarIcon)
        XCTAssertTrue(manager.showQuotaInMenuBar)
        manager.toggleItem(second)
        XCTAssertEqual(manager.currentItems, [first])

        manager.toggleItem(first)
        manager.autoSelectNewAccounts(availableItems: [first, second])
        XCTAssertTrue(manager.currentItems.isEmpty)
        XCTAssertTrue(manager.hasUserModifiedMenuBar)
    }

    func testReplacementPreservesPositionOtherHostsAndPersistsSelection() {
        let repository = MenuBarPreferencesRepositoryFake()
        let manager = MenuBarSettingsManager(repository: repository)
        manager.currentHostID = "host-a"
        manager.menuBarMaxItems = 2
        let first = MenuBarQuotaItem(provider: "claude", accountKey: "personal", hostID: "host-a")
        let old = MenuBarQuotaItem(provider: "codex", accountKey: "unavailable", hostID: "host-a")
        let foreign = MenuBarQuotaItem(provider: "codex", accountKey: "unavailable", hostID: "host-b")
        let replacement = MenuBarQuotaItem(provider: "gemini", accountKey: "work", hostID: "host-a")
        manager.selectedItems = [first, foreign, old]
        manager.showMenuBarIcon = false
        manager.showQuotaInMenuBar = false

        manager.replaceItem(old, with: replacement)

        XCTAssertEqual(manager.selectedItems, [first, foreign, replacement])
        XCTAssertTrue(manager.isAtMaxItems)
        XCTAssertTrue(manager.showMenuBarIcon)
        XCTAssertTrue(manager.showQuotaInMenuBar)
        XCTAssertTrue(manager.hasUserModifiedMenuBar)
        XCTAssertEqual(repository.savedPreferences.last?.selectedItems, manager.selectedItems)
        manager.autoSelectNewAccounts(availableItems: [old])
        XCTAssertEqual(manager.selectedItems, [first, foreign, replacement])
    }

    func testReplacementRejectsDuplicatesMissingPinsAndOtherHosts() {
        let manager = MenuBarSettingsManager(repository: MenuBarPreferencesRepositoryFake())
        let first = MenuBarQuotaItem(provider: "claude", accountKey: "personal", hostID: "host-a")
        let second = MenuBarQuotaItem(provider: "codex", accountKey: "work", hostID: "host-a")
        let missing = MenuBarQuotaItem(provider: "gemini", accountKey: "missing", hostID: "host-a")
        let foreign = MenuBarQuotaItem(provider: "codex", accountKey: "work", hostID: "host-b")
        manager.selectedItems = [first, second]

        manager.replaceItem(first, with: second)
        manager.replaceItem(missing, with: foreign)
        manager.replaceItem(missing, with: missing)
        manager.replaceItem(first, with: foreign)

        XCTAssertEqual(manager.selectedItems, [first, second])
        XCTAssertFalse(manager.hasUserModifiedMenuBar)
    }

    func testSelectionCapacityIsIndependentForEachHost() {
        let manager = MenuBarSettingsManager(repository: MenuBarPreferencesRepositoryFake())
        manager.menuBarMaxItems = 1
        for host in ["host-a", "host-b"] {
            manager.currentHostID = host
            XCTAssertFalse(manager.isAtMaxItems)
            manager.addItem(.init(provider: "codex", accountKey: "same-account", hostID: host))
            XCTAssertTrue(manager.isAtMaxItems)
        }
        XCTAssertEqual(manager.selectedItems.count, 2)
        XCTAssertEqual(manager.currentItems.count, 1)
    }

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
