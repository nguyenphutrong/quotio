import Foundation
import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class UserDefaultsPreferenceRepositoriesTests: XCTestCase {
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

        XCTAssertEqual(repository.load().mode, .localProxy)
        XCTAssertEqual(defaults.string(forKey: "operatingMode"), "local")
        XCTAssertTrue(defaults.bool(forKey: "migratedToOperatingMode"))
        XCTAssertEqual(defaults.string(forKey: "appMode"), "full")
        XCTAssertEqual(defaults.string(forKey: "connectionMode"), "local")

        defaults.set("quotaOnly", forKey: "appMode")
        XCTAssertEqual(repository.load().mode, .localProxy)
        XCTAssertEqual(defaults.string(forKey: "operatingMode"), "local")
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

    func testRemovedMenuBarProviderIsFilteredAndMigrationIsIdempotent() throws {
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
            [MenuBarQuotaItem(provider: "claude", accountKey: "active")]
        )
        XCTAssertEqual(repository.load().selectedItems.count, 1)
    }

    func testMenuBarProviderFilterUsesExistingKey() {
        defaults.set(QuotaProvider.claude.rawValue, forKey: "menuBarSelectedProvider")
        let repository = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)

        XCTAssertEqual(repository.load().selectedProvider, .claude)

        var preferences = repository.load()
        preferences.selectedProvider = nil
        repository.save(preferences)

        XCTAssertEqual(defaults.string(forKey: "menuBarSelectedProvider"), "")
        XCTAssertNil(repository.load().selectedProvider)
    }

    func testEmptyStoresUseExistingDefaults() {
        let menu = UserDefaultsMenuBarPreferencesRepository(defaults: defaults).load()
        let refresh = UserDefaultsRefreshPreferencesRepository(defaults: defaults).load()
        let warmup = UserDefaultsWarmupPreferencesRepository(defaults: defaults).load()
        let appearance = UserDefaultsAppearancePreferencesRepository(defaults: defaults).load()
        let language = UserDefaultsLanguagePreferencesRepository(defaults: defaults).load()
        let update = UserDefaultsUpdatePreferencesRepository(defaults: defaults).load()
        let telemetry = UserDefaultsTelemetryPreferencesRepository(defaults: defaults).load()
        let notifications = UserDefaultsNotificationPreferencesRepository(defaults: defaults).load()
        let proxy = UserDefaultsProxyPreferencesRepository(defaults: defaults).load()
        let tunnel = UserDefaultsTunnelPreferencesRepository(defaults: defaults).load()
        let appShell = UserDefaultsAppShellPreferencesRepository(defaults: defaults).load()

        XCTAssertEqual(menu, MenuBarPreferences())
        XCTAssertEqual(refresh, RefreshPreferences())
        XCTAssertEqual(warmup, WarmupPreferences())
        XCTAssertEqual(appearance, AppearancePreferences())
        XCTAssertEqual(language, LanguagePreferences())
        XCTAssertEqual(update, UpdatePreferences())
        XCTAssertEqual(telemetry, TelemetryPreferences())
        XCTAssertEqual(notifications, NotificationPreferences())
        XCTAssertEqual(proxy, ProxyPreferences())
        XCTAssertEqual(tunnel, TunnelPreferences())
        XCTAssertEqual(appShell, AppShellPreferences())
    }

    func testRepositoriesRoundTripUsingExistingKeysAndFormats() throws {
        let modeRepository = UserDefaultsOperatingModePreferencesRepository(defaults: defaults)
        modeRepository.save(OperatingModePreferences(mode: .localProxy, hasCompletedOnboarding: true))
        XCTAssertEqual(defaults.string(forKey: "operatingMode"), "local")
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))

        let menuPreferences = MenuBarPreferences(
            showMenuBarIcon: false,
            showQuotaInMenuBar: false,
            menuBarMaxItems: 4,
            selectedItems: [MenuBarQuotaItem(provider: "codex", accountKey: "user")],
            selectedProvider: .codex,
            colorMode: .monochrome,
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .ring,
            stackPairedQuotaMetrics: false,
            hideSensitiveInfo: true,
            totalUsageMode: .combined,
            modelAggregationMode: .average,
            hasUserModifiedMenuBar: true
        )
        let menuRepository = UserDefaultsMenuBarPreferencesRepository(defaults: defaults)
        menuRepository.save(menuPreferences)
        XCTAssertEqual(menuRepository.load(), menuPreferences)
        XCTAssertNotNil(defaults.data(forKey: "menuBarSelectedQuotaItems"))
        XCTAssertEqual(defaults.string(forKey: "menuBarSelectedProvider"), "codex")

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

        let telemetryPreferences = TelemetryPreferences(
            shareAnonymousUsage: true,
            anonymousInstallID: "install-id",
            hasSentFirstOptInLaunch: true
        )
        let telemetryRepository = UserDefaultsTelemetryPreferencesRepository(defaults: defaults)
        telemetryRepository.save(telemetryPreferences)
        XCTAssertEqual(telemetryRepository.load(), telemetryPreferences)

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
