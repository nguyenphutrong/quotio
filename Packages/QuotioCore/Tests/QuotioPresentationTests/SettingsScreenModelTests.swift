import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class SettingsScreenModelTests: XCTestCase {
    func testLoadsPreferencesFromRepository() {
        let proxyPreferences = ProxyPreferences(
            autoStartProxy: true,
            allowNetworkAccess: true,
            proxyURL: "http://localhost:8080"
        )
        let tunnelPreferences = TunnelPreferences(autoStartTunnel: true, autoRestartTunnel: true)
        let appShellPreferences = AppShellPreferences(autoCheckUpdates: false, showInDock: false)
        let repository = InMemorySettingsPreferencesRepository(
            proxyPreferences: proxyPreferences,
            tunnelPreferences: tunnelPreferences,
            appShellPreferences: appShellPreferences
        )

        let model = makeModel(repository: repository)

        XCTAssertEqual(model.proxyPreferences, proxyPreferences)
        XCTAssertEqual(model.tunnelPreferences, tunnelPreferences)
        XCTAssertEqual(model.appShellPreferences, appShellPreferences)
    }

    func testSettersPersistOnlyTheirFeatureValues() async {
        let repository = InMemorySettingsPreferencesRepository()
        let model = makeModel(repository: repository)

        model.setAutoStartProxy(true)
        model.setAutoStartTunnel(true)
        model.setAutoRestartTunnel(true)
        model.setLoggingToFile(false)
        model.setHideGettingStarted(true)
        await model.setProxyURL("http://localhost:8080")

        XCTAssertEqual(repository.proxyPreferences, model.proxyPreferences)
        XCTAssertEqual(repository.tunnelPreferences, model.tunnelPreferences)
        XCTAssertEqual(repository.appShellPreferences, model.appShellPreferences)
        XCTAssertEqual(repository.writeCount, 6)
    }

    func testPlatformEffectsRunBeforePersistence() {
        let repository = InMemorySettingsPreferencesRepository()
        var networkValueWhenApplied: Bool?
        var updateValueWhenApplied: Bool?
        var dockValueWhenApplied: Bool?
        let model = SettingsScreenModel(
            proxyRepository: repository,
            tunnelRepository: repository,
            appShellRepository: repository,
            applyNetworkAccess: { _ in
                networkValueWhenApplied = repository.proxyPreferences.allowNetworkAccess
            },
            applyAutomaticUpdateChecks: { _ in
                updateValueWhenApplied = repository.appShellPreferences.autoCheckUpdates
            },
            applyDockVisibility: { _ in
                dockValueWhenApplied = repository.appShellPreferences.showInDock
            }
        )

        model.setAllowNetworkAccess(true)
        model.setAutomaticUpdateChecks(false)
        model.setShowInDock(false)

        XCTAssertEqual(networkValueWhenApplied, false)
        XCTAssertEqual(updateValueWhenApplied, true)
        XCTAssertEqual(dockValueWhenApplied, true)
        XCTAssertTrue(repository.proxyPreferences.allowNetworkAccess)
        XCTAssertFalse(repository.appShellPreferences.autoCheckUpdates)
        XCTAssertFalse(repository.appShellPreferences.showInDock)
    }

    func testProxyURLReloadsQuotaNetworkAfterPersistence() async {
        let repository = InMemorySettingsPreferencesRepository()
        var persistedValueWhenReloaded: String?
        let model = SettingsScreenModel(
            proxyRepository: repository,
            tunnelRepository: repository,
            appShellRepository: repository,
            reloadQuotaNetwork: {
                persistedValueWhenReloaded = repository.proxyPreferences.proxyURL
            }
        )

        await model.setProxyURL("http://localhost:8080")

        XCTAssertEqual(persistedValueWhenReloaded, "http://localhost:8080")
    }

    private func makeModel(repository: InMemorySettingsPreferencesRepository) -> SettingsScreenModel {
        SettingsScreenModel(
            proxyRepository: repository,
            tunnelRepository: repository,
            appShellRepository: repository
        )
    }
}

private final class InMemorySettingsPreferencesRepository:
    ProxyPreferencesRepository,
    TunnelPreferencesRepository,
    AppShellPreferencesRepository,
    @unchecked Sendable
{
    private(set) var proxyPreferences: ProxyPreferences
    private(set) var tunnelPreferences: TunnelPreferences
    private(set) var appShellPreferences: AppShellPreferences
    private(set) var writeCount = 0

    init(
        proxyPreferences: ProxyPreferences = ProxyPreferences(),
        tunnelPreferences: TunnelPreferences = TunnelPreferences(),
        appShellPreferences: AppShellPreferences = AppShellPreferences()
    ) {
        self.proxyPreferences = proxyPreferences
        self.tunnelPreferences = tunnelPreferences
        self.appShellPreferences = appShellPreferences
    }

    func load() -> ProxyPreferences {
        proxyPreferences
    }

    func load() -> TunnelPreferences {
        tunnelPreferences
    }

    func load() -> AppShellPreferences {
        appShellPreferences
    }

    func setAutoStartProxy(_ enabled: Bool) {
        proxyPreferences.autoStartProxy = enabled
        writeCount += 1
    }

    func setAllowNetworkAccess(_ enabled: Bool) {
        proxyPreferences.allowNetworkAccess = enabled
        writeCount += 1
    }

    func setLoggingToFile(_ enabled: Bool) {
        proxyPreferences.loggingToFile = enabled
        writeCount += 1
    }

    func setProxyURL(_ proxyURL: String?) {
        proxyPreferences.proxyURL = proxyURL
        writeCount += 1
    }

    func setAutoStartTunnel(_ enabled: Bool) {
        tunnelPreferences.autoStartTunnel = enabled
        writeCount += 1
    }

    func setAutoRestartTunnel(_ enabled: Bool) {
        tunnelPreferences.autoRestartTunnel = enabled
        writeCount += 1
    }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        appShellPreferences.autoCheckUpdates = enabled
        writeCount += 1
    }

    func setShowInDock(_ enabled: Bool) {
        appShellPreferences.showInDock = enabled
        writeCount += 1
    }

    func setHideGettingStarted(_ hidden: Bool) {
        appShellPreferences.hideGettingStarted = hidden
        writeCount += 1
    }
}
