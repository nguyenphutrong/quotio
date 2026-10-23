import AppKit
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class StatusBarMenuSnapshotMapperTests: XCTestCase {
    func testEmptyHostFailureMapsOneGlobalWarningAndRecoveryClearsIt() {
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: Date(), reason: .credentialStorage)
        var quota = QuotaSnapshot(providerNames: [.claude: "Claude", .codex: "Codex"], hostIssue: issue)
        func snapshot() -> StatusBarMenuSnapshot {
            StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
            )
        }
        XCTAssertTrue(snapshot().providers.isEmpty)
        XCTAssertEqual(snapshot().hostWarning?.issue, issue)
        XCTAssertEqual(snapshot().hostWarning?.recoveryAction, .authorize)
        quota.hostIssue = nil
        XCTAssertNil(snapshot().hostWarning)
    }

    func testRetainedFailurePreservesReadingAndLastSuccessfulUpdateUntilRecovery() throws {
        let id = QuotaAccountID(provider: .claude, accountKey: "work")
        let updated = Date(timeIntervalSince1970: 1_000)
        let reading = ProviderQuota(models: [QuotaMetric(name: "Session", percentage: 42, resetTime: "")],
                                    lastUpdated: updated)
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: updated.addingTimeInterval(60),
                                      reason: .credentialStorage, recoveryAction: .authorize)
        var quota = QuotaSnapshot(
            accountStates: [id: .init(connection: .connected, quota: .stale)],
            quotas: [.claude: ["work": reading]], accountIssues: [id: issue]
        )
        func mappedAccount() throws -> StatusBarMenuAccountSnapshot {
            let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
            )
            return try XCTUnwrap(snapshot.providers.first?.accounts.first)
        }
        let stale = try mappedAccount()
        XCTAssertEqual(stale.quota, reading)
        XCTAssertEqual(stale.warning?.lastSuccessfulUpdate, updated)
        XCTAssertEqual(stale.warning?.issue, issue)
        XCTAssertEqual(stale.warning?.recoveryAction, .authorize)
        XCTAssertEqual(stale.warning?.isStale, true)

        quota.accountStates[id] = .init(connection: .connected, quota: .fresh)
        quota.accountIssues.removeValue(forKey: id)
        let recovered = try mappedAccount()
        XCTAssertNil(recovered.warning)
        XCTAssertEqual(recovered.quota, reading)
    }

    func testProviderFailureFallsBackOnlyForAccountsWithoutFreshState() throws {
        let staleID = QuotaAccountID(provider: .codex, accountKey: "stale")
        let freshID = QuotaAccountID(provider: .codex, accountKey: "fresh")
        let updated = Date(timeIntervalSince1970: 1_000)
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: updated.addingTimeInterval(60), reason: .timeout)
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(
                accountStates: [freshID: .init(connection: .connected, quota: .fresh)],
                quotas: [.codex: ["stale": ProviderQuota(lastUpdated: updated), "fresh": ProviderQuota(lastUpdated: updated)]],
                issues: [.codex: issue]
            ),
            menuBarPreferences: MenuBarPreferences(), language: .english
        )
        let accounts = try XCTUnwrap(snapshot.providers.first?.accounts)
        XCTAssertEqual(accounts.first { $0.id == staleID }?.warning?.issue, issue)
        XCTAssertNil(accounts.first { $0.id == freshID }?.warning)
    }

    func testProviderFailureRemainsVisibleWithoutMetricsAndRespectsSelectionAndTracking() throws {
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: Date(), reason: .credentialStorage)
        let quota = QuotaSnapshot(issues: [.claude: issue])
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [], quota: quota,
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude), language: .english
        )
        XCTAssertEqual(snapshot.providers.map(\.provider), [.claude])
        XCTAssertEqual(snapshot.selectedProvider, .claude)
        let provider = try XCTUnwrap(snapshot.providers.first)
        XCTAssertTrue(provider.accounts.isEmpty)
        XCTAssertEqual(provider.warning?.issue, issue)
        XCTAssertNil(provider.warning?.lastSuccessfulUpdate)

        let disabled = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [], quota: quota,
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude), language: .english,
            trackingPreferences: .init(disabledProviders: [.claude])
        )
        XCTAssertTrue(disabled.providers.isEmpty)
        XCTAssertNil(disabled.selectedProvider)
    }

    func testAccountFailureWithoutMetricsIsVisibleUnlessAccountDisabled() {
        let id = QuotaAccountID(provider: .claude, accountKey: "work")
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: Date(), reason: .timeout, recoveryAction: .retry)
        let quota = QuotaSnapshot(accountStates: [id: .init(connection: .connected, quota: .failed(.timeout))],
                                  accountIssues: [id: issue])
        let visible = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
        )
        XCTAssertEqual(visible.providers.first?.accounts.first?.warning?.issue, issue)
        XCTAssertNil(visible.providers.first?.accounts.first?.quota)
        XCTAssertNil(visible.providers.first?.warning)
        let disabled = Account.make(providerID: .init(rawValue: "claude"), accountKey: "work",
                                    source: .nativeCredential, status: .disabled)
        let hidden = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [disabled], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
        )
        XCTAssertTrue(hidden.providers.isEmpty)
    }
    func testFailedAccountWithoutQuotaRemainsVisibleBesideHealthyAccount() throws {
        let failedID = QuotaAccountID(provider: .claude, accountKey: "failed")
        let healthyID = QuotaAccountID(provider: .claude, accountKey: "healthy")
        let failedAccount = Account.make(providerID: .init(rawValue: "claude"), accountKey: "failed",
                                         displayName: "Failed login", source: .nativeCredential)
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: Date(), reason: .timeout, recoveryAction: .retry)
        let reading = ProviderQuota(models: [QuotaMetric(name: "Session", percentage: 62, resetTime: "")])
        var quota = QuotaSnapshot(
            accountStates: [healthyID: .init(connection: .connected, quota: .fresh),
                            failedID: .init(connection: .connected, quota: .failed(.timeout))],
            quotas: [.claude: ["healthy": reading]], accountIssues: [failedID: issue]
        )
        func snapshot() -> StatusBarMenuSnapshot {
            StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [failedAccount], quota: quota,
                menuBarPreferences: MenuBarPreferences(selectedProvider: .claude), language: .english
            )
        }
        let accounts = try XCTUnwrap(snapshot().providers.first?.accounts)
        XCTAssertEqual(Set(accounts.map(\.id)), Set([failedID, healthyID]))
        let failed = try XCTUnwrap(accounts.first { $0.id == failedID })
        XCTAssertEqual(failed.email, failedAccount.displayName)
        XCTAssertNil(failed.quota)
        XCTAssertNil(failed.warning?.lastSuccessfulUpdate)
        XCTAssertEqual(failed.warning?.issue, issue)
        XCTAssertEqual(failed.warning?.recoveryAction, .retry)
        let healthy = try XCTUnwrap(accounts.first { $0.id == healthyID })
        XCTAssertEqual(healthy.quota, reading)
        XCTAssertNil(healthy.warning)
        XCTAssertNil(snapshot().providers.first?.warning)

        quota.accountStates[failedID] = .init(connection: .connected, quota: .fresh)
        quota.accountIssues.removeValue(forKey: failedID)
        XCTAssertEqual(snapshot().providers.first?.accounts.map(\.id), [healthyID])
    }


    func testMetricGroupsPreserveHostOrderAndExcludeExtraUsage() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "5 hours", percentage: 50, resetTime: "", group: "Standard"),
            QuotaMetric(name: "Weekly", percentage: 60, resetTime: "", group: "Standard"),
            QuotaMetric(name: "5 hours", percentage: 70, resetTime: "", group: "Core"),
            QuotaMetric(name: "Extra usage", percentage: -1, resetTime: "", presentation: .amount(value: 0, unit: .credits, semantics: .balance))
        ])
        XCTAssertEqual(quota.metricGroups.map(\.name), ["Standard", "Core"])
        XCTAssertEqual(quota.metricGroups.map { $0.models.count }, [2, 1])
        XCTAssertEqual(quota.models.filter(\.isStandaloneMetric).count, 1)
    }

    func testDisabledAccountsMatchOpaqueIDsExactly() {
        let disabled = Account.make(providerID: .init(rawValue: "codex"), accountKey: "Account-A", source: .nativeCredential, status: .disabled)
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [disabled],
            quota: QuotaSnapshot(quotas: [.codex: ["Account-A": ProviderQuota(), "account-a": ProviderQuota()]]),
            menuBarPreferences: MenuBarPreferences(), language: .english
        )
        XCTAssertEqual(snapshot.providers.first?.accounts.map(\.id.accountKey), ["account-a"])
    }

    func testMenuUsesHostProviderNamesWithoutAClientProviderSwitch() throws {
        let provider = try XCTUnwrap(QuotaProvider(rawValue: "future-provider"))
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(providerNames: [provider: "Host Provider Name"], quotas: [provider: ["account": ProviderQuota()]]),
            menuBarPreferences: MenuBarPreferences(), language: .english
        )
        XCTAssertEqual(snapshot.providers.first?.displayName, "Host Provider Name")
        XCTAssertFalse(snapshot.canRefresh)
        XCTAssertEqual(snapshot.providers.first?.supportsScopedRefresh, false)
        XCTAssertEqual(snapshot.providers.first?.accounts.first?.isRefreshBlocked, true)
    }

    func testDisabledProviderIsHiddenDespiteCachedQuota() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [.claude: ["Work": ProviderQuota()]]),
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            language: .english,
            trackingPreferences: .init(disabledProviders: [.claude])
        )
        XCTAssertTrue(snapshot.providers.isEmpty)
        XCTAssertNil(snapshot.selectedProvider)
    }

    func testMonitorSnapshotMapsProvidersAccountsStateAndDisplaySettings() throws {
        let enabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.amp.rawValue),
            accountKey: "monitor@example.com",
            source: .nativeCredential
        )
        let disabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "disabled@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let quota = QuotaSnapshot(
            canRefresh: true,
            quotas: [
                .antigravity: [
                    "alpha-key": ProviderQuota(accountDisplayName: "alpha@example.com"),
                    "zulu-key": ProviderQuota(accountDisplayName: "Zulu@example.com"),
                ],
                .claude: [
                    "claude-key": ProviderQuota(accountDisplayName: "claude@example.com"),
                ],
            ],
            refreshingProviders: [.antigravity]
        )
        let preferences = MenuBarPreferences(
            selectedProvider: .amp,
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .detailed,
            hideSensitiveInfo: true,
            modelAggregationMode: .average
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [enabledMonitorAccount, disabledMonitorAccount],
            quota: quota,
            menuBarPreferences: preferences,
            language: .vietnamese
        )

        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .claude])
        XCTAssertNil(snapshot.selectedProvider)
        XCTAssertTrue(snapshot.isLoadingQuotas)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayMode, .remaining)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayStyle, .detailed)
        XCTAssertTrue(snapshot.displaySettings.hideSensitiveInfo)
        XCTAssertEqual(snapshot.displaySettings.modelAggregationMode, .average)
        XCTAssertEqual(snapshot.language, .vietnamese)

        let antigravity = try XCTUnwrap(snapshot.providers.first { $0.provider == .antigravity })
        XCTAssertTrue(antigravity.isRefreshing)
        XCTAssertTrue(antigravity.supportsScopedRefresh)
        XCTAssertEqual(antigravity.accounts.map(\.email), [
            "alpha@example.com",
            "Zulu@example.com",
        ])
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshing))
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshBlocked))
    }

    func testSnapshotUsesOnlyHostProviderData() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [
                .antigravity: ["antigravity": ProviderQuota()],
                .claude: ["claude": ProviderQuota()],
                .codex: ["codex": ProviderQuota()],
            ]),
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            language: .english
        )

        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .claude, .codex])
        XCTAssertEqual(snapshot.selectedProvider, .claude)
    }

    func testSnapshotOnlyIncludesEnabledAccountsWithQuota() {
        let disabledAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.claude.rawValue),
            accountKey: "disabled@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [disabledAccount],
            quota: QuotaSnapshot(quotas: [
                .claude: ["disabled@example.com": ProviderQuota()],
                .codex: ["enabled@example.com": ProviderQuota()],
            ]),
            menuBarPreferences: MenuBarPreferences(),
            language: .english
        )

        XCTAssertEqual(snapshot.providers.map(\.provider), [.codex])
        XCTAssertEqual(snapshot.providers.first?.accounts.map(\.email), ["enabled@example.com"])
    }
}

@MainActor
final class StatusBarMenuRendererTests: XCTestCase {
    func testTrackedMenuResizesExistingAccountViewWhenWarningAppearsAndClears() throws {
        _ = NSApplication.shared
        guard ProcessInfo.processInfo.environment["QUOTIO_MENU_TRACKING_TESTS"] == "1" else {
            throw XCTSkip("Set QUOTIO_MENU_TRACKING_TESTS=1 in a logged-in macOS session")
        }
        @MainActor final class GeometryResult {
            var itemID: ObjectIdentifier?
            var viewID: ObjectIdentifier?
            var freshHeight: CGFloat = 0
            var completedStages = 0
        }
        for style in [QuotaDisplayStyle.comfortable, .compact] {
            let result = GeometryResult()
            let id = QuotaAccountID(provider: .claude, accountKey: "work")
            let manager = StatusBarManager()
            var quota = QuotaSnapshot(
                accountStates: [id: .init(connection: .connected, quota: .fresh)],
                quotas: [.claude: ["work": ProviderQuota(models: [
                    QuotaMetric(name: "Session", percentage: 62, resetTime: "")
                ])]]
            )
            let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
                refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
                pairIPhone: {}, openApp: {}, openProviderSettings: { _ in }, quit: {}, menuNeedsRebuild: {}
            ))
            manager.configureMenu(snapshotProvider: {
                StatusBarMenuSnapshotMapper.makeSnapshot(
                    monitorAccounts: [], quota: quota,
                    menuBarPreferences: MenuBarPreferences(selectedProvider: .claude, quotaDisplayStyle: style), language: .english
                )
            }, commandDispatcher: commands)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = manager
            manager.menuWillOpen(menu)
            let tick: @MainActor @Sendable (Int) -> Void = { stage in
                guard let item = menu.items.first(where: { $0.title == "work" }), let view = item.view else {
                    XCTFail("Missing tracked account view")
                    menu.cancelTracking()
                    return
                }
                view.layoutSubtreeIfNeeded()
                switch stage {
                case 0:
                    XCTAssertNotNil(view.window)
                    result.itemID = ObjectIdentifier(item)
                    result.viewID = ObjectIdentifier(view)
                    result.freshHeight = view.bounds.height
                    quota.accountStates[id] = .init(connection: .connected, quota: .stale)
                    quota.accountIssues[id] = .init(kind: .failed, occurredAt: Date(), reason: .credentialStorage)
                    manager.rebuildMenuInPlace()
                case 1:
                    XCTAssertEqual(ObjectIdentifier(item), result.itemID)
                    XCTAssertEqual(ObjectIdentifier(view), result.viewID)
                    XCTAssertGreaterThan(view.bounds.height, result.freshHeight)
                    XCTAssertGreaterThanOrEqual(view.bounds.height + 0.5, view.intrinsicContentSize.height)
                    quota.accountStates[id] = .init(connection: .connected, quota: .fresh)
                    quota.accountIssues.removeValue(forKey: id)
                    manager.rebuildMenuInPlace()
                default:
                    XCTAssertEqual(ObjectIdentifier(item), result.itemID)
                    XCTAssertEqual(ObjectIdentifier(view), result.viewID)
                    XCTAssertEqual(view.bounds.height, result.freshHeight, accuracy: 0.5)
                    menu.cancelTracking()
                }
                result.completedStages += 1
            }
            let timers = [0.1, 0.3, 0.5].enumerated().map { stage, delay in
                Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { tick(stage) }
                }
            }
            timers.forEach { RunLoop.main.add($0, forMode: .eventTracking) }
            menu.popUp(positioning: nil, at: NSPoint(x: 400, y: 400), in: nil)
            timers.forEach { $0.invalidate() }
            XCTAssertEqual(result.completedStages, 3)
        }
    }

    func testWarningOnlyAccountHasAccountScopedRecoveryBesideHealthyCardInBothDensities() async throws {
        _ = NSApplication.shared
        let failedID = QuotaAccountID(provider: .claude, accountKey: "failed")
        let account = Account.make(providerID: .init(rawValue: "claude"), accountKey: "failed",
                                   displayName: "Failed login", source: .nativeCredential)
        let refreshed = expectation(description: "warning-only account refresh")
        refreshed.expectedFulfillmentCount = 2
        var requested: [QuotaAccountID] = []
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { id in requested.append(id); refreshed.fulfill() },
            selectProvider: { _ in }, pairIPhone: {}, openApp: {}, openProviderSettings: { _ in }, quit: {}, menuNeedsRebuild: {}
        ))
        for style in [QuotaDisplayStyle.comfortable, .compact] {
            let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [account],
                quota: QuotaSnapshot(
                    canRefresh: true,
                    accountStates: [failedID: .init(connection: .connected, quota: .failed(.timeout))],
                    quotas: [.claude: ["healthy": ProviderQuota()]],
                    accountIssues: [failedID: .init(kind: .failed, occurredAt: Date(), reason: .timeout)]
                ),
                menuBarPreferences: MenuBarPreferences(selectedProvider: .claude, quotaDisplayStyle: style), language: .english
            )
            let menu = StatusBarMenuRenderer(snapshot: snapshot, commands: commands).buildMenu()
            let healthy = try XCTUnwrap(menu.items.first { $0.title == "healthy" })
            let failed = try XCTUnwrap(menu.items.first { $0.title == account.displayName })
            XCTAssertFalse(healthy.isHidden)
            XCTAssertFalse(failed.isHidden)
            XCTAssertGreaterThan(try XCTUnwrap(failed.view).bounds.height, 0)
            let submenu = try XCTUnwrap(failed.submenu)
            let recovery = try XCTUnwrap(submenu.items.first { $0.identifier?.rawValue == "quotaRecovery" })
            XCTAssertTrue(recovery.isEnabled)
            submenu.performActionForItem(at: submenu.index(of: recovery))
        }
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(requested, [failedID, failedID])
    }

    func testOpenMenuRecoveryChangesFromRetryToCredentialReviewAndClearsOnSuccess() throws {
        _ = NSApplication.shared
        let id = QuotaAccountID(provider: .claude, accountKey: "work")
        var reviewed: [QuotaProvider?] = []
        var retries = 0
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: { retries += 1 }, refreshProvider: { _ in retries += 1 }, refreshAccount: { _ in retries += 1 },
            selectProvider: { _ in }, pairIPhone: {}, openApp: {},
            openProviderSettings: { reviewed.append($0) }, quit: {}, menuNeedsRebuild: {}
        ))
        var quota = QuotaSnapshot(
            accountStates: [id: .init(connection: .connected, quota: .fresh)],
            quotas: [.claude: ["work": ProviderQuota(models: [QuotaMetric(name: "Session", percentage: 62, resetTime: "")])]]
        )
        func snapshot() -> StatusBarMenuSnapshot {
            StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
            )
        }
        let renderer = StatusBarMenuRenderer(snapshot: snapshot(), commands: commands)
        let menu = renderer.buildMenu()
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "work" }?.submenu)
        let recovery = try XCTUnwrap(submenu.items.first { $0.identifier?.rawValue == "quotaRecovery" })
        XCTAssertTrue(recovery.isHidden)
        XCTAssertFalse(recovery.isEnabled)
        quota.accountStates[id] = .init(connection: .connected, quota: .stale)
        quota.accountIssues[id] = .init(kind: .failed, occurredAt: Date(), reason: .timeout)
        renderer.update(snapshot: snapshot())
        XCTAssertFalse(recovery.isHidden)
        XCTAssertFalse(recovery.isEnabled)
        quota.accountIssues[id] = .init(kind: .failed, occurredAt: Date(), reason: .credentialStorage)
        renderer.update(snapshot: snapshot())
        XCTAssertTrue(recovery.isEnabled)
        submenu.performActionForItem(at: submenu.index(of: recovery))
        XCTAssertEqual(reviewed, [.claude])
        XCTAssertEqual(retries, 0)

        quota.accountIssues[id] = .init(kind: .failed, occurredAt: Date(), reason: .timeout)
        renderer.update(snapshot: snapshot())
        XCTAssertFalse(recovery.isEnabled)
        quota.accountStates[id] = .init(connection: .connected, quota: .fresh)
        quota.accountIssues.removeValue(forKey: id)
        renderer.update(snapshot: snapshot())
        XCTAssertFalse(recovery.isEnabled)
        XCTAssertTrue(recovery.isHidden)
        XCTAssertNil(snapshot().providers.first?.accounts.first?.warning)
    }

    func testHostFailureRendersOnceOnlyWhenNoProviderSectionsExist() {
        _ = NSApplication.shared
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, openProviderSettings: { _ in }, quit: {}, menuNeedsRebuild: {}
        ))
        var quota = QuotaSnapshot(
            providerNames: [.claude: "Claude", .codex: "Codex"],
            hostIssue: .init(kind: .failed, occurredAt: Date(), reason: .credentialStorage)
        )
        func menu() -> NSMenu {
            let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
            )
            return StatusBarMenuRenderer(snapshot: snapshot, commands: commands).buildMenu()
        }
        XCTAssertEqual(menu().items.filter { $0.identifier?.rawValue == "quotaHostIssue" }.count, 1)
        XCTAssertFalse(menu().items.contains { $0.identifier?.rawValue == "quotaProviderIssue" })
        quota.quotas = [.claude: ["work": ProviderQuota()]]
        XCTAssertFalse(menu().items.contains { $0.identifier?.rawValue == "quotaHostIssue" })
        quota.quotas = [:]
        quota.hostIssue = nil
        XCTAssertFalse(menu().items.contains { $0.identifier?.rawValue == "quotaHostIssue" })
    }

    func testRetainedFailureAddsWarningInBothDensitiesAndNativeRecoveryOpensProviderSettings() throws {
        _ = NSApplication.shared
        let id = QuotaAccountID(provider: .claude, accountKey: "work")
        let updated = Date(timeIntervalSince1970: 1_000)
        var reviewed: [QuotaProvider?] = []
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, openProviderSettings: { reviewed.append($0) }, quit: {}, menuNeedsRebuild: {}
        ))
        for style in [QuotaDisplayStyle.comfortable, .compact] {
            var quota = QuotaSnapshot(
                accountStates: [id: .init(connection: .connected, quota: .fresh)],
                quotas: [.claude: ["work": ProviderQuota(lastUpdated: updated, accountDisplayName: "Work")]]
            )
            func snapshot() -> StatusBarMenuSnapshot {
                StatusBarMenuSnapshotMapper.makeSnapshot(
                    monitorAccounts: [], quota: quota,
                    menuBarPreferences: MenuBarPreferences(quotaDisplayStyle: style), language: .english
                )
            }
            let freshMenu = StatusBarMenuRenderer(snapshot: snapshot(), commands: commands).buildMenu()
            let freshCard = try XCTUnwrap(freshMenu.items.first { $0.title == "Work" })
            let freshHeight = try XCTUnwrap(freshCard.view).bounds.height
            XCTAssertNil(freshCard.submenu)

            quota.accountStates[id] = .init(connection: .connected, quota: .stale)
            quota.accountIssues[id] = .init(kind: .failed, occurredAt: updated.addingTimeInterval(60),
                                           reason: .credentialStorage, recoveryAction: .authorize)
            let renderer = StatusBarMenuRenderer(snapshot: snapshot(), commands: commands)
            let menu = renderer.buildMenu()
            let staleCard = try XCTUnwrap(menu.items.first { $0.title == "Work" })
            XCTAssertGreaterThan(try XCTUnwrap(staleCard.view).bounds.height, freshHeight)
            let submenu = try XCTUnwrap(staleCard.submenu)
            let recovery = try XCTUnwrap(submenu.items.first { $0.identifier?.rawValue == "quotaRecovery" })
            XCTAssertTrue(recovery.isEnabled)
            XCTAssertNotNil(recovery.target)
            XCTAssertNotNil(recovery.action)
            submenu.performActionForItem(at: submenu.index(of: recovery))

            quota.accountStates[id] = .init(connection: .connected, quota: .fresh)
            quota.accountIssues.removeValue(forKey: id)
            renderer.update(snapshot: snapshot())
            XCTAssertFalse(recovery.isEnabled)
        }
        XCTAssertEqual(reviewed, [.claude, .claude])
    }

    func testNativeRetryRecoveryTracksRefreshAvailability() throws {
        _ = NSApplication.shared
        let id = QuotaAccountID(provider: .claude, accountKey: "work")
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, openProviderSettings: { _ in }, quit: {}, menuNeedsRebuild: {}
        ))
        var quota = QuotaSnapshot(
            accountStates: [id: .init(connection: .connected, quota: .stale)],
            quotas: [.claude: ["work": ProviderQuota()]],
            accountIssues: [id: .init(kind: .failed, occurredAt: Date(), reason: .timeout, recoveryAction: .retry)]
        )
        func snapshot() -> StatusBarMenuSnapshot {
            StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [], quota: quota, menuBarPreferences: MenuBarPreferences(), language: .english
            )
        }
        let renderer = StatusBarMenuRenderer(snapshot: snapshot(), commands: commands)
        let menu = renderer.buildMenu()
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "work" }?.submenu)
        let recovery = try XCTUnwrap(submenu.items.first { $0.identifier?.rawValue == "quotaRecovery" })
        XCTAssertFalse(recovery.isEnabled)
        quota.canRefresh = true
        renderer.update(snapshot: snapshot())
        XCTAssertTrue(recovery.isEnabled)
        quota.refreshingProviders = [.claude]
        renderer.update(snapshot: snapshot())
        XCTAssertFalse(recovery.isEnabled)
    }

    func testProviderFailureWithoutMetricsRendersAndKeepsSelectedProviderFilter() throws {
        _ = NSApplication.shared
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, openProviderSettings: { _ in }, quit: {}, menuNeedsRebuild: {}
        ))
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(issues: [
                .claude: .init(kind: .failed, occurredAt: Date(), reason: .credentialStorage),
                .codex: .init(kind: .failed, occurredAt: Date(), reason: .timeout)
            ]),
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude), language: .english
        )
        let menu = StatusBarMenuRenderer(snapshot: snapshot, commands: commands).buildMenu()
        let issues = menu.items.filter { $0.identifier?.rawValue == "quotaProviderIssue" }
        XCTAssertEqual(issues.count, 2)
        let claude = try XCTUnwrap(issues.first { $0.representedObject as? String == QuotaProvider.claude.rawValue })
        let codex = try XCTUnwrap(issues.first { $0.representedObject as? String == QuotaProvider.codex.rawValue })
        XCTAssertFalse(claude.isHidden)
        XCTAssertTrue(codex.isHidden)
        XCTAssertGreaterThan(try XCTUnwrap(claude.view).bounds.height, 0)
    }

    func testQuotaCardHeightDoesNotDependOnResetAvailability() throws {
        _ = NSApplication.shared
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, openProviderSettings: { _ in }, quit: {}, menuNeedsRebuild: {}
        ))
        let scenarios: [(QuotaProvider, [(String, String?)])] = [
            (.antigravity, [("Session", nil), ("Weekly", nil), ("Claude Session", nil), ("Claude Weekly", nil)]),
            (.factoryDroid, [("5 hours", "Standard"), ("Weekly", "Standard"), ("Monthly", "Standard"), ("5 hours", "Core"), ("Weekly", "Core"), ("Monthly", "Core")])
        ]
        for (provider, metrics) in scenarios {
            func cardHeight(_ resetTimes: [String]) throws -> CGFloat {
                let models = metrics.enumerated().map { index, metric in
                    QuotaMetric(name: metric.0, percentage: 50, resetTime: resetTimes[index], group: metric.1)
                }
                let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
                    monitorAccounts: [], quota: QuotaSnapshot(quotas: [provider: ["Account": ProviderQuota(models: models)]]),
                    menuBarPreferences: MenuBarPreferences(selectedProvider: provider, quotaDisplayStyle: .comfortable), language: .english
                )
                let renderer = StatusBarMenuRenderer(snapshot: snapshot, commands: commands)
                let menu = renderer.buildMenu()
                let item = try XCTUnwrap(menu.items.first { $0.title == "Account" })
                return try XCTUnwrap(item.view).bounds.height
            }
            let future = "2099-01-01T00:00:00Z"
            let expected = try cardHeight(Array(repeating: future, count: metrics.count))
            for resetTimes in [
                Array(repeating: "", count: metrics.count),
                metrics.indices.map { $0.isMultiple(of: 2) ? "" : future },
                Array(repeating: "invalid", count: metrics.count),
                Array(repeating: "2000-01-01T00:00:00Z", count: metrics.count)
            ] {
                XCTAssertEqual(try cardHeight(resetTimes), expected, accuracy: 0.5, provider.rawValue)
            }
        }
    }

    func testProviderFilterHidesItemsWithoutReplacingTrackedMenuContents() {
        var selections: [QuotaProvider?] = []
        let controller = StatusBarProviderFilterController(selectedProvider: nil) {
            selections.append($0)
        }
        let menu = NSMenu()
        let claudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        let codexItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
        let providerHeader = NSMenuItem(title: "Header", action: nil, keyEquivalent: "")
        menu.items = [providerHeader, claudeItem, codexItem]
        controller.register(providerHeader, scope: .allProvidersOnly)
        controller.register(claudeItem, scope: .provider(.claude))
        controller.register(codexItem, scope: .provider(.codex))
        controller.activate(in: menu)
        let originalItems = menu.items.map(ObjectIdentifier.init)

        controller.select(.claude)

        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), originalItems)
        XCTAssertTrue(providerHeader.isHidden)
        XCTAssertFalse(claudeItem.isHidden)
        XCTAssertTrue(codexItem.isHidden)
        XCTAssertEqual(selections, [.claude])
    }

}

@MainActor
final class StatusBarCommandDispatcherTests: XCTestCase {
    func testPairingDoesNotOpenMainWindowOrRefreshQuota() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) { recorder.rebuildCount += 1 }
        dispatcher.dispatch(.pairIPhone)
        XCTAssertEqual(recorder.pairIPhoneCount, 1)
        XCTAssertEqual(recorder.openAppCount, 0)
        XCTAssertEqual(recorder.rebuildCount, 0)
        XCTAssertTrue(recorder.asyncCommands.isEmpty)
    }

    func testAsyncCommandsRouteAndRebuildAfterCompletion() async {
        let recorder = StatusBarCommandRecorder()
        let rebuilds = expectation(description: "menu rebuilt after async commands")
        rebuilds.expectedFulfillmentCount = 3
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
            rebuilds.fulfill()
        }

        dispatcher.dispatch(.refreshAll)
        dispatcher.dispatch(.refreshProvider(.claude))
        dispatcher.dispatch(.refreshAccount(QuotaAccountID(provider: .codex, accountKey: "person@example.com")))

        await fulfillment(of: [rebuilds], timeout: 1)
        XCTAssertEqual(Set(recorder.asyncCommands), Set([
            "refreshAll",
            "refreshProvider:claude",
            "refreshAccount:codex:person@example.com",
        ]))
        XCTAssertEqual(recorder.rebuildCount, 3)
    }

    func testSynchronousCommandsRouteWithoutUnnecessaryRebuilds() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.openApp)
        dispatcher.dispatch(.openProviderSettings(.claude))
        dispatcher.dispatch(.openProviderSettings(nil))
        dispatcher.dispatch(.quit)
        dispatcher.dispatch(.selectProvider(.claude))
        dispatcher.dispatch(.selectProvider(nil))

        XCTAssertEqual(recorder.selectedProviders, [.claude, nil])
        XCTAssertEqual(recorder.openAppCount, 1)
        XCTAssertEqual(recorder.openedProviderSettings, [.claude, nil])
        XCTAssertEqual(recorder.quitCount, 1)
        XCTAssertEqual(recorder.rebuildCount, 0)
    }

    private func makeDispatcher(
        recorder: StatusBarCommandRecorder,
        menuNeedsRebuild: @escaping () -> Void
    ) -> StatusBarCommandDispatcher {
        StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: { recorder.asyncCommands.append("refreshAll") },
            refreshProvider: { provider in
                recorder.asyncCommands.append("refreshProvider:\(provider.rawValue)")
            },
            refreshAccount: { account in
                recorder.asyncCommands.append(
                    "refreshAccount:\(account.provider.rawValue):\(account.accountKey)"
                )
            },
            selectProvider: { recorder.selectedProviders.append($0) },
            pairIPhone: { recorder.pairIPhoneCount += 1 },
            openApp: { recorder.openAppCount += 1 },
            openProviderSettings: { recorder.openedProviderSettings.append($0) },
            quit: { recorder.quitCount += 1 },
            menuNeedsRebuild: menuNeedsRebuild
        ))
    }
}

@MainActor
private final class StatusBarCommandRecorder {
    var asyncCommands: [String] = []
    var selectedProviders: [QuotaProvider?] = []
    var pairIPhoneCount = 0
    var openAppCount = 0
    var openedProviderSettings: [QuotaProvider?] = []
    var quitCount = 0
    var rebuildCount = 0
}
