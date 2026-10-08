import Foundation
import AppKit
import SwiftUI
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class QuotaFeatureControllerTests: XCTestCase {
    func testProviderFailureDoesNotMarkAnUnaffectedAccountFailed() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "person@example.com", source: .nativeCredential
        )
        let fixture = await makeFixture(
            account: account, provider: .codex, lastUpdated: Date(),
            issues: [.codex: .init(kind: .failed, occurredAt: Date().addingTimeInterval(10), reason: .authentication)]
        )
        XCTAssertEqual(fixture.controller.monitorStatus(for: account).status, "ready")
        await fixture.controller.shutdown()
    }

    func testMonitorStatusKeepsQuotaFreshForTwoRefreshIntervals() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "person@example.com", source: .nativeCredential
        )
        let fixture = await makeFixture(
            account: account, provider: .codex, lastUpdated: Date().addingTimeInterval(-900)
        )
        XCTAssertEqual(fixture.controller.monitorStatus(for: account).status, "ready")
        await fixture.controller.shutdown()
    }

    func testInitializeReadsHostStateWithoutDiscoveringNativeAccounts() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "person@example.com",
            source: .nativeCredential
        )
        let fixture = await makeFixture(account: account, provider: .codex)
        await fixture.accountService.clearEvents()

        await fixture.controller.initialize()

        let events = await fixture.accountService.events()
        XCTAssertFalse(events.contains("discover"))
        XCTAssertTrue(events.contains("accounts"))
        await fixture.controller.shutdown()
    }

    func testSettingsChangesUseHostPersistence() async {
        let account = Account.make(providerID: .init(rawValue: "codex"), accountKey: "fixture", source: .nativeCredential)
        let fixture = await makeFixture(account: account, provider: .codex)
        await fixture.controller.initialize()
        await fixture.controller.setAutomaticDiscovery(false)
        await fixture.controller.setProviderEnabled(false, provider: .codex)
        await fixture.controller.setRefreshInterval(123)
        XCTAssertFalse(fixture.controller.trackingPreferences.automaticallyDiscoverLogins)
        XCTAssertFalse(fixture.controller.trackingPreferences.isEnabled(.codex))
        XCTAssertEqual(fixture.controller.monitoringSettings?.refreshInterval, 123)
        XCTAssertNil(fixture.controller.settingsError)
        await fixture.controller.shutdown()
    }

    func testRefreshDoesNotNormalizeOpaqueAccountIDsOrRemoveHostQuota() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.kiro.rawValue),
            accountKey: "Person@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let fixture = await makeFixture(
            account: account,
            provider: .kiro,
            quotaAccountKey: "person@example.com"
        )

        await fixture.controller.refresh(provider: .kiro)

        XCTAssertNotNil(fixture.quota.providerQuotas[.kiro]?["person@example.com"])
        await fixture.controller.shutdown()
    }

    func testRemovingBorrowedAccountSubmitsTheHostRemovalWithoutReenablingIt() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.cursor.rawValue),
            accountKey: "person@example.com",
            source: .localIDE,
            capabilities: [.disable, .delete],
            status: .disabled
        )
        let fixture = await makeFixture(account: account, provider: .cursor)

        await fixture.controller.remove(account: QuotaAccountID(
            provider: .cursor,
            accountKey: account.accountKey
        ))

        let disabledUpdates = await fixture.accountService.disabledUpdates()
        let deletedAccountIDs = await fixture.accountService.deletedAccountIDs()
        XCTAssertEqual(disabledUpdates, [])
        XCTAssertEqual(deletedAccountIDs, [account.id])
        XCTAssertNotNil(fixture.quota.providerQuotas[.cursor]?[account.accountKey])
        await fixture.controller.shutdown()
    }

    func testRemovingOwnedAccountReloadsQuotaInsteadOfEditingTheHostSnapshot() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.openRouter.rawValue),
            accountKey: "Personal",
            source: .quotioKeychain,
            capabilities: [.disable, .delete, .edit]
        )
        let fixture = await makeFixture(account: account, provider: .openRouter)

        await fixture.controller.remove(account: QuotaAccountID(
            provider: .openRouter,
            accountKey: account.accountKey
        ))

        let disabledUpdates = await fixture.accountService.disabledUpdates()
        let deletedAccountIDs = await fixture.accountService.deletedAccountIDs()
        XCTAssertEqual(disabledUpdates, [])
        XCTAssertEqual(deletedAccountIDs, [account.id])
        XCTAssertNotNil(fixture.quota.providerQuotas[.openRouter]?[account.accountKey])
        await fixture.controller.shutdown()
    }

    func testMenuBarSelectionMigratesAliasesWithoutDuplicatingAccounts() async {
        let canonical = MenuBarQuotaItem(provider: "codex", accountKey: "same@example.com")
        let legacy = MenuBarQuotaItem(provider: "codex", accountKey: "same@example.com-pro")
        let account = Account.make(
            providerID: AccountProviderID(rawValue: "codex"),
            accountKey: canonical.accountKey,
            source: .nativeCredential
        )
        let fixture = await makeFixture(
            account: account, provider: .codex,
            aliases: [legacy.accountKey: canonical.accountKey]
        )
        await fixture.controller.refresh(provider: .codex)
        XCTAssertNotNil(fixture.quota.providerQuotas[.codex]?[canonical.accountKey])
        fixture.menuBar.selectedItems = []
        fixture.menuBar.toggleItem(legacy)

        fixture.controller.synchronizeMenuBarSelection()

        XCTAssertEqual(fixture.menuBar.selectedItems, [canonical])
        fixture.menuBar.selectedItems = [legacy, canonical]
        fixture.controller.synchronizeMenuBarSelection()
        XCTAssertEqual(fixture.menuBar.selectedItems, [canonical])
        fixture.menuBar.selectedItems = [
            MenuBarQuotaItem(provider: "codex", accountKey: "codex-same@example.com-pro.json")
        ]
        fixture.controller.synchronizeMenuBarSelection()
        XCTAssertEqual(fixture.menuBar.selectedItems, [MenuBarQuotaItem(provider: "codex", accountKey: "codex-same@example.com-pro.json")])
        XCTAssertTrue(fixture.menuBar.hasUserModifiedMenuBar)
        await fixture.controller.shutdown()
    }

    func testHostAccountsDoNotEraseUnresolvedSelections() async {
        let account = Account.make(providerID: AccountProviderID(rawValue: "claude"), accountKey: "Personal", source: .quotioKeychain)
        let fixture = await makeFixture(account: account, provider: .claude)
        fixture.menuBar.selectedItems = []
        fixture.controller.synchronizeMenuBarSelection()
        XCTAssertFalse(fixture.menuBar.selectedItems.contains { $0.accountKey == "Work" })
        let unresolved = MenuBarQuotaItem(provider: "claude", accountKey: "Work")
        fixture.menuBar.toggleItem(unresolved)
        fixture.controller.synchronizeMenuBarSelection()
        XCTAssertTrue(fixture.menuBar.selectedItems.contains(unresolved))

        let sameName = await makeFixture(
            account: Account.make(providerID: AccountProviderID(rawValue: "claude"), accountKey: "Work", source: .quotioKeychain),
            provider: .claude
        )
        sameName.menuBar.selectedItems = [MenuBarQuotaItem(provider: "claude", accountKey: "Work")]
        sameName.controller.synchronizeMenuBarSelection()
        XCTAssertEqual(sameName.menuBar.selectedItems, [MenuBarQuotaItem(provider: "claude", accountKey: "Work")])
        await fixture.controller.shutdown()
        await sameName.controller.shutdown()
    }

    func testHostRedirectsNeverRetargetAnotherHostsPin() async {
        let account = Account.make(providerID: .init(rawValue: "codex"), accountKey: "current", source: .nativeCredential)
        let fixture = await makeFixture(account: account, provider: .codex, aliases: ["legacy":"current"], hostID: "host-a")
        let foreign = MenuBarQuotaItem(provider: "codex", accountKey: "legacy", hostID: "host-b")
        fixture.menuBar.selectedItems = [foreign, .init(provider: "codex", accountKey: "legacy")]
        fixture.controller.synchronizeMenuBarSelection()
        XCTAssertEqual(fixture.menuBar.selectedItems, [foreign, .init(provider: "codex", accountKey: "current", hostID: "host-a")])
        await fixture.controller.shutdown()
    }

    func testReadOnlyHostDoesNotChangeMonitoringSettings() async {
        let account = Account.make(providerID: .init(rawValue: "codex"), accountKey: "account", source: .nativeCredential)
        let fixture = await makeFixture(account: account, provider: .codex, canManageSettings: false)
        await fixture.controller.initialize()
        let before = fixture.controller.monitoringSettings
        await fixture.controller.setRefreshInterval(0)
        await fixture.controller.setProviderEnabled(false, provider: .codex)
        XCTAssertEqual(fixture.controller.monitoringSettings, before)
        await fixture.controller.shutdown()
    }

    func testProviderRowStaysCompactAtNarrowWidths() async {
        let account = Account.make(providerID: .init(rawValue: "amp"),
            accountKey: "long.account.name@example.com", source: .nativeCredential)
        let fixture = await makeFixture(account: account, provider: .amp)
        await fixture.controller.initialize()
        let state = ProviderSettingsState(provider: .amp, accounts: fixture.controller.accounts.accounts,
            permissions: [], quota: fixture.quota.state, tracking: fixture.controller.trackingPreferences)
        XCTAssertEqual(state.accounts.count, 1)
        for width: CGFloat in [360, 480] {
            let view = ProviderAccountsSection(state: state, visibleAccounts: state.accounts)
                .environment(AccountsSettingsScreenModel())
                .environment(NavigationScreenModel())
                .environment(fixture.controller.accounts)
                .environment(fixture.quota)
                .environment(fixture.controller)
                .environment(fixture.menuBar)
                .environment(ProviderImageScreenModel { _, _ in nil })
                .frame(width: width)
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
            XCTAssertGreaterThan(host.fittingSize.height, 40)
            XCTAssertLessThan(host.fittingSize.height, 140,
                "A provider with one account must stay a header plus one compact row")
        }
        await fixture.controller.shutdown()
    }

    func testGitHubHostIsForwardedOnlyForMonitorCopilot() async throws {
        let authorizer = QuotaFeatureOAuthAuthorizer()
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.copilot.rawValue),
            accountKey: "person",
            source: .nativeCredential
        )
        let fixture = await makeFixture(account: account, provider: .copilot, oauthAuthorizer: authorizer)
        let host = try XCTUnwrap(GitHubHost("octocorp.ghe.com"))

        for (index, provider) in [QuotaProvider.copilot, .codex].enumerated() {
            await fixture.controller.startOAuth(for: provider, githubHost: host)
            for _ in 0..<200 where await authorizer.requests().count <= index {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let requests = await authorizer.requests()
        XCTAssertEqual(requests.map(\.providerID.rawValue), ["copilot", "codex"])
        XCTAssertEqual(requests.map(\.githubHost), [host, nil])
        await fixture.controller.shutdown()
    }

    private func makeFixture(
        account: Account,
        provider: QuotaProvider,
        quotaAccountKey: String? = nil,
        aliases: [String: String] = [:],
        hostID: String? = nil,
        canManageSettings: Bool = true,
        lastUpdated: Date = Date(timeIntervalSince1970: 1_000),
        issues: [QuotaProvider: QuotaRefreshIssue] = [:],
        oauthAuthorizer: QuotaFeatureOAuthAuthorizer = QuotaFeatureOAuthAuthorizer()
    ) async -> (
        controller: QuotaFeatureController,
        accountService: QuotaFeatureAccountService,
        quota: QuotaScreenModel,
        menuBar: MenuBarSettingsManager
    ) {
        let accountService = QuotaFeatureAccountService(accounts: [account])
        let accounts = AccountsScreenModel(
            accountService: accountService
        )
        let quota = QuotaScreenModel(coordinator: TestQuotaCoordinator(
            snapshot: QuotaSnapshot(
                hostID: hostID,
                canManageSettings: canManageSettings,
                quotas: [
                provider: [
                    quotaAccountKey ?? account.accountKey: ProviderQuota(
                        lastUpdated: lastUpdated
                    ),
                ],
                ],
                accountAliases: aliases.isEmpty ? [:] : [provider: aliases],
                issues: issues
            )
        ))
        await quota.bootstrap(mode: .monitor)
        await accounts.reloadAccounts()
        let preferences = QuotaFeaturePreferencesRepository()
        let menuBar = MenuBarSettingsManager(repository: preferences)
        let controller = QuotaFeatureController(
            quota: quota,
            accounts: accounts,
            oauth: OAuthScreenModel(controller: OAuthFlowController(authorizer: oauthAuthorizer)),
            modeManager: OperatingModeManager(repository: preferences),
            monitoringSettings: QuotaFeatureMonitoringSettings(),
            menuBarSettings: menuBar,
            notifications: NotificationController(
                repository: preferences,
                delivery: QuotaFeatureNotificationDelivery()
            )
        )
        return (controller, accountService, quota, menuBar)
    }
}

@MainActor
private final class QuotaFeatureNotificationDelivery: NotificationDelivering {
    func requestAuthorization() async -> NotificationAuthorizationStatus { .denied }
    func authorizationStatus() async -> NotificationAuthorizationStatus { .denied }
    func deliver(_ notification: SemanticNotification) {}
    func removeAllPending() {}
    func removeAllDelivered() {}
}

private actor QuotaFeatureAccountService: AccountManaging {
    struct DisabledUpdate: Equatable, Sendable {
        let accountID: String
        let disabled: Bool
    }

    private var storedAccounts: [Account]
    private var recordedDisabledUpdates: [DisabledUpdate] = []
    private var recordedDeletedAccountIDs: [String] = []
    private var recordedEvents: [String] = []

    init(accounts: [Account]) {
        storedAccounts = accounts
    }

    func registerDetectedNativeAccounts() { recordedEvents.append("discover") }
    func rescanNativeAccounts(for provider: QuotaProvider) {}
    func nativeDiscoverySnapshot() -> NativeDiscoverySnapshot { .init() }
    func authorizeNativeSource(_ source: NativeSourcePermission) {}
    func accounts() -> [Account] {
        recordedEvents.append("accounts")
        return storedAccounts
    }

    func setDisabled(_ disabled: Bool, accountID: String) {
        recordedDisabledUpdates.append(DisabledUpdate(accountID: accountID, disabled: disabled))
    }

    func delete(accountID: String) {
        recordedDeletedAccountIDs.append(accountID)
        storedAccounts.removeAll { $0.id == accountID }
    }

    func renameResolvedAccount(id: String, userLabel: String?) async throws {}
    func setSourceEnabled(_ enabled: Bool, sourceID: String) async throws {}
    func unlinkSource(sourceID: String) async throws {}

    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?,
        fields: [String: String] = [:]
    ) {}

    func disabledUpdates() -> [DisabledUpdate] { recordedDisabledUpdates }
    func deletedAccountIDs() -> [String] { recordedDeletedAccountIDs }
    func events() -> [String] { recordedEvents }
    func clearEvents() { recordedEvents = [] }
}

private actor QuotaFeatureOAuthAuthorizer: OAuthAuthorizing {
    private var recordedRequests: [OAuthAuthorizationRequest] = []

    func requests() -> [OAuthAuthorizationRequest] { recordedRequests }

    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        recordedRequests.append(request)
        throw OAuthFlowFailure.unsupportedProvider
    }

    func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        throw OAuthFlowFailure.unsupportedProvider
    }

    func cancel(attemptID: OAuthAttemptID) async {}
}

private final class QuotaFeaturePreferencesRepository:
    OperatingModePreferencesRepository,
    RefreshPreferencesRepository,
    MenuBarPreferencesRepository,
    NotificationPreferencesRepository,
    @unchecked Sendable
{
    func load() -> OperatingModePreferences {
        OperatingModePreferences(mode: .monitor, hasCompletedOnboarding: true)
    }

    func save(_ preferences: OperatingModePreferences) {}

    func load() -> RefreshPreferences {
        RefreshPreferences(cadence: .manual)
    }

    func save(_ preferences: RefreshPreferences) {}

    func load() -> MenuBarPreferences { MenuBarPreferences() }
    func save(_ preferences: MenuBarPreferences) {}

    func load() -> NotificationPreferences {
        NotificationPreferences(notificationsEnabled: false)
    }

    func save(_ preferences: NotificationPreferences) {}
}

private actor QuotaFeatureMonitoringSettings: MonitoringSettingsManaging {
    var value = MonitoringSettings(revision: "fixture", enabledProviders: Set(QuotaProvider.allCases.map(\.rawValue)), disabledProviders: [], automaticallyDiscoverLogins: true, refreshInterval: 600)
    func monitoringProviders() -> [MonitoringProvider] { QuotaProvider.allCases.map { .init(id: $0, displayName: $0.rawValue, actions: [], inputs: []) } }
    func monitoringSettings() -> MonitoringSettings { value }
    func updateMonitoringSettings(_ settings: MonitoringSettings) -> MonitoringSettings {
        value = settings
        return value
    }
}
