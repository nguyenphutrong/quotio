import Foundation
import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class UserDefaultsPreferenceRepositoriesTests: XCTestCase {
    func testMenuPinsRoundTripPerHostWithoutTruncatingAnotherHostsSelection() {
        let repository = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)
        let pins = ["host-a", "host-b"].flatMap { host in
            (0..<3).map { MenuBarQuotaItem(provider: "codex", accountKey: "account-\($0)", hostID: host) }
        }
        repository.save(MenuBarPreferences(menuBarMaxItems: 2, selectedItems: pins))
        let restored = repository.load().selectedItems
        XCTAssertEqual(restored.count, 4)
        XCTAssertEqual(Set(restored.map(\.id)).count, 4)
        XCTAssertEqual(restored.filter { $0.hostID == "host-a" }.count, 2)
        XCTAssertEqual(restored.filter { $0.hostID == "host-b" }.count, 2)
    }

    func testLocalProxyMigrationKeepsAutoStartAndAuthFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.json")
        let contents = Data("synthetic credential fixture".utf8)
        try contents.write(to: file)
        defaults.set("local", forKey: "operatingMode")
        defaults.set(directory.path, forKey: "authDirectory")
        defaults.set(true, forKey: "autoStartProxy")
        let repository = UserDefaultsOperatingModePreferencesRepository(defaults: defaults)
        XCTAssertEqual(repository.load().mode, .monitor)
        XCTAssertEqual(repository.load().mode, .monitor)
        XCTAssertTrue(defaults.bool(forKey: "autoStartProxy"))
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertEqual(defaults.string(forKey: "authDirectory"), directory.path)
    }

    func testProviderTrackingRoundTripsWithoutChangingAccountsOrProxyPreferences() {
        defaults.set(["existing-account"], forKey: "disabledAccountIDs")
        defaults.set(true, forKey: "autoStartProxy")
        let repository = UserDefaultsProviderTrackingPreferencesRepository(defaults: defaults)
        XCTAssertEqual(repository.load(), ProviderTrackingPreferences())
        repository.save(ProviderTrackingPreferences(disabledProviders: [.claude, .codex]))
        XCTAssertEqual(repository.load().disabledProviders, [.claude, .codex])
        repository.save(ProviderTrackingPreferences())
        XCTAssertTrue(repository.load().isEnabled(.claude))
        XCTAssertEqual(defaults.stringArray(forKey: "disabledAccountIDs"), ["existing-account"])
        XCTAssertTrue(defaults.bool(forKey: "autoStartProxy"))
    }

    func testLegacyDevinPreferencesCannotAliasTheCanonicalDevinAPIProvider() throws {
        defaults.set(["devin", "github-copilot"], forKey: "disabledProviders")
        defaults.set("devin", forKey: "menuBarSelectedProvider")
        defaults.set(try JSONEncoder().encode([MenuBarQuotaItem(provider: "devin", accountKey: "account")]), forKey: "menuBarSelectedQuotaItems")
        let tracking = UserDefaultsProviderTrackingPreferencesRepository(defaults: defaults)
        let menu = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)
        XCTAssertEqual(tracking.load().disabledProviders, [.devin, .copilot])
        XCTAssertEqual(menu.load().selectedProvider?.rawValue, "devin-desktop")
        XCTAssertEqual(menu.load().selectedItems.first?.provider, "devin-desktop")
        let cloud = try XCTUnwrap(QuotaProvider(rawValue: "devin"))
        XCTAssertNotEqual(cloud, .devin)
        tracking.save(.init(disabledProviders: [cloud]))
        var selection = menu.load()
        selection.selectedProvider = cloud
        selection.selectedItems = [.init(provider: "devin", accountKey: "cloud-account")]
        menu.save(selection)
        XCTAssertEqual(tracking.load().disabledProviders, [cloud])
        XCTAssertEqual(menu.load().selectedProvider, cloud)
        XCTAssertEqual(menu.load().selectedItems.first?.provider, "devin")
        XCTAssertEqual(defaults.stringArray(forKey: "disabledProviders"), ["devin", "github-copilot"])
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UserDefaultsPreferenceRepositoriesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLegacyOperatingModeMigrationIsIdempotentAndRetainsLegacyKeys() {
        defaults.set("full", forKey: "appMode")
        defaults.set("local", forKey: "connectionMode")
        let repository = UserDefaultsOperatingModePreferencesRepository(defaults: defaults)

        XCTAssertEqual(repository.load().mode, .monitor)
        XCTAssertEqual(defaults.string(forKey: "operatingMode"), "monitor")
        XCTAssertTrue(defaults.bool(forKey: "migratedToOperatingMode"))
        XCTAssertEqual(defaults.string(forKey: "appMode"), "full")
        XCTAssertEqual(defaults.string(forKey: "connectionMode"), "local")

        defaults.set("quotaOnly", forKey: "appMode")
        XCTAssertEqual(repository.load().mode, .monitor)
        XCTAssertEqual(defaults.string(forKey: "operatingMode"), "monitor")
    }

    func testCurrentOperatingModeTakesPrecedenceOverLegacyFixture() {
        defaults.set("monitor", forKey: "operatingMode")
        defaults.set("full", forKey: "appMode")
        defaults.set("local", forKey: "connectionMode")

        let loaded = UserDefaultsOperatingModePreferencesRepository(defaults: defaults).load()

        XCTAssertEqual(loaded.mode, .monitor)
        XCTAssertNil(defaults.object(forKey: "migratedToOperatingMode"))
    }

    func testLanguageMigrationIsIdempotent() {
        defaults.set("zh", forKey: "appLanguage")
        let repository = UserDefaultsLanguagePreferencesRepository(defaults: defaults)

        XCTAssertEqual(repository.load().language, .chinese)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "zh-Hans")
        XCTAssertEqual(repository.load().language, .chinese)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "zh-Hans")
    }

    func testLegacyMenuBarMigrationDoesNotOverwriteItsOriginalData() throws {
        let legacyItems = [
            MenuBarQuotaItem(provider: "gemini-cli", accountKey: "removed"),
            MenuBarQuotaItem(provider: "claude", accountKey: "active"),
        ]
        defaults.set(try JSONEncoder().encode(legacyItems), forKey: "menuBarSelectedQuotaItems")
        let repository = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)

        XCTAssertEqual(repository.load().selectedItems, [MenuBarQuotaItem(provider: "claude", accountKey: "active")])
        let migratedData = try XCTUnwrap(defaults.data(forKey: "menuBarSelectedQuotaItems"))
        XCTAssertEqual(
            try JSONDecoder().decode([MenuBarQuotaItem].self, from: migratedData),
            legacyItems
        )
        XCTAssertEqual(repository.load().selectedItems.count, 1)
    }

    func testMenuBarProviderFilterMigratesIntoAtomicCanonicalSelection() {
        defaults.set(QuotaProvider.claude.rawValue, forKey: "menuBarSelectedProvider")
        let repository = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)

        XCTAssertEqual(repository.load().selectedProvider, .claude)

        var preferences = repository.load()
        preferences.selectedProvider = nil
        repository.save(preferences)

        XCTAssertEqual(defaults.string(forKey: "menuBarSelectedProvider"), "claude")
        XCTAssertEqual(defaults.dictionary(forKey: "menuBarProviderSelectionV2")?["provider"] as? String, "")
        XCTAssertNil(repository.load().selectedProvider)
    }

    func testEmptyStoresUseExistingDefaults() {
        let menu = UserDefaultsMenuBarPreferencesRepository(defaults: defaults).load()
        let refresh = UserDefaultsRefreshPreferencesRepository(defaults: defaults).load()
        let warmup = UserDefaultsWarmupPreferencesRepository(defaults: defaults).load()
        let appearance = UserDefaultsAppearancePreferencesRepository(defaults: defaults).load()
        let language = UserDefaultsLanguagePreferencesRepository(defaults: defaults).load()
        let update = UserDefaultsUpdatePreferencesRepository(defaults: defaults).load()
        let notifications = UserDefaultsNotificationPreferencesRepository(defaults: defaults).load()
        let proxy = UserDefaultsProxyPreferencesRepository(defaults: defaults).load()
        let tunnel = UserDefaultsTunnelPreferencesRepository(defaults: defaults).load()
        let appShell = UserDefaultsAppShellPreferencesRepository(defaults: defaults).load()

        XCTAssertEqual(menu, MenuBarPreferences())
        XCTAssertEqual(menu.colorMode, .monochrome)
        XCTAssertEqual(menu.colorBasis, .remaining)
        XCTAssertEqual(menu.quotaDisplayMode, .remaining)
        XCTAssertEqual(refresh, RefreshPreferences())
        XCTAssertEqual(warmup, WarmupPreferences())
        XCTAssertEqual(appearance, AppearancePreferences())
        XCTAssertEqual(language, LanguagePreferences())
        XCTAssertEqual(update, UpdatePreferences())
        XCTAssertEqual(notifications, NotificationPreferences())
        XCTAssertEqual(proxy, ProxyPreferences())
        XCTAssertEqual(tunnel, TunnelPreferences())
        XCTAssertEqual(appShell, AppShellPreferences())
    }

    func testRepositoriesRoundTripUsingExistingKeysAndFormats() throws {
        let modeRepository = UserDefaultsOperatingModePreferencesRepository(defaults: defaults)
        modeRepository.save(OperatingModePreferences(mode: .localProxy, hasCompletedOnboarding: true))
        XCTAssertEqual(defaults.string(forKey: "operatingMode"), "monitor")
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))

        let menuPreferences = MenuBarPreferences(
            showMenuBarIcon: false,
            showQuotaInMenuBar: false,
            menuBarMaxItems: 4,
            selectedItems: [MenuBarQuotaItem(provider: "codex", accountKey: "user")],
            selectedProvider: .codex,
            colorMode: .monochrome,
            colorBasis: .pace,
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .detailed,
            stackPairedQuotaMetrics: false,
            hideSensitiveInfo: true,
            totalUsageMode: .combined,
            modelAggregationMode: .average,
            hasUserModifiedMenuBar: true
        )
        let menuRepository = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)
        menuRepository.save(menuPreferences)
        XCTAssertEqual(menuRepository.load(), menuPreferences)
        XCTAssertEqual(defaults.string(forKey: "menuBarColorBasis"), "pace")
        XCTAssertNotNil(defaults.dictionary(forKey: "menuBarProviderSelectionV2")?["items"] as? Data)
        XCTAssertEqual(defaults.dictionary(forKey: "menuBarProviderSelectionV2")?["provider"] as? String, "codex")

        let warmupPreferences = WarmupPreferences(
            enabledAccountIds: ["codex::user"],
            cadence: .thirtyMinutes,
            scheduleMode: .daily,
            dailyMinutes: 600,
            selectedModelsByAccount: ["codex::user": ["gpt-5"]],
            cadenceByAccount: ["codex::user": "2h"],
            scheduleModeByAccount: ["codex::user": "daily"],
            dailyMinutesByAccount: ["codex::user": 720]
        )
        let warmupRepository = UserDefaultsWarmupPreferencesRepository(defaults: defaults)
        warmupRepository.save(warmupPreferences)
        XCTAssertEqual(warmupRepository.load(), warmupPreferences)

        let refreshRepository = UserDefaultsRefreshPreferencesRepository(defaults: defaults)
        refreshRepository.save(RefreshPreferences(cadence: .twoMinutes))
        XCTAssertEqual(refreshRepository.load(), RefreshPreferences(cadence: .twoMinutes))

        let appearanceRepository = UserDefaultsAppearancePreferencesRepository(defaults: defaults)
        appearanceRepository.save(AppearancePreferences(mode: .dark))
        XCTAssertEqual(appearanceRepository.load(), AppearancePreferences(mode: .dark))

        let languageRepository = UserDefaultsLanguagePreferencesRepository(defaults: defaults)
        languageRepository.save(LanguagePreferences(language: .french))
        XCTAssertEqual(languageRepository.load(), LanguagePreferences(language: .french))

        let updateRepository = UserDefaultsUpdatePreferencesRepository(defaults: defaults)
        updateRepository.save(UpdatePreferences(channel: .beta))
        XCTAssertEqual(updateRepository.load(), UpdatePreferences(channel: .beta))

        let notificationPreferences = NotificationPreferences(
            notificationsEnabled: false,
            quotaAlertThreshold: 10,
            notifyOnQuotaLow: false,
            notifyOnCooling: false,
            notifyOnProxyCrash: false,
            notifyOnUpgradeAvailable: false
        )
        let notificationRepository = UserDefaultsNotificationPreferencesRepository(defaults: defaults)
        notificationRepository.save(notificationPreferences)
        XCTAssertEqual(notificationRepository.load(), notificationPreferences)

        let proxyRepository = UserDefaultsProxyPreferencesRepository(defaults: defaults)
        proxyRepository.setAutoStartProxy(true)
        proxyRepository.setAllowNetworkAccess(true)
        proxyRepository.setLoggingToFile(false)
        proxyRepository.setProxyURL("http://127.0.0.1:8080")
        XCTAssertEqual(
            proxyRepository.load(),
            ProxyPreferences(
                autoStartProxy: true,
                allowNetworkAccess: true,
                loggingToFile: false,
                proxyURL: "http://127.0.0.1:8080"
            )
        )
        XCTAssertEqual(defaults.string(forKey: "proxyURL"), "http://127.0.0.1:8080")

        let tunnelRepository = UserDefaultsTunnelPreferencesRepository(defaults: defaults)
        tunnelRepository.setAutoStartTunnel(true)
        tunnelRepository.setAutoRestartTunnel(true)
        XCTAssertEqual(
            tunnelRepository.load(),
            TunnelPreferences(autoStartTunnel: true, autoRestartTunnel: true)
        )

        let appShellRepository = UserDefaultsAppShellPreferencesRepository(defaults: defaults)
        appShellRepository.setAutomaticUpdateChecks(false)
        appShellRepository.setShowInDock(false)
        appShellRepository.setHideGettingStarted(true)
        XCTAssertEqual(
            appShellRepository.load(),
            AppShellPreferences(autoCheckUpdates: false, showInDock: false, hideGettingStarted: true)
        )
    }

    func testProxySettersPreserveOtherCurrentValuesAndEmptyURLPresence() {
        defaults.set(true, forKey: "allowNetworkAccess")
        defaults.set(false, forKey: "loggingToFile")
        let repository = UserDefaultsProxyPreferencesRepository(defaults: defaults)

        repository.setAutoStartProxy(true)

        XCTAssertTrue(defaults.bool(forKey: "autoStartProxy"))
        XCTAssertTrue(defaults.bool(forKey: "allowNetworkAccess"))
        XCTAssertFalse(defaults.bool(forKey: "loggingToFile"))

        repository.setProxyURL("")
        XCTAssertNotNil(defaults.object(forKey: "proxyURL"))
        XCTAssertEqual(repository.load().proxyURL, "")

        repository.setProxyURL(nil)
        XCTAssertNil(defaults.object(forKey: "proxyURL"))
    }
}
