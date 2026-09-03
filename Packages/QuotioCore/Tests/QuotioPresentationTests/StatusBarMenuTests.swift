import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class StatusBarMenuSnapshotMapperTests: XCTestCase {
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
        let tunnel = CloudflareTunnelSnapshot(
            status: .active,
            publicURL: "https://example.trycloudflare.com",
            startTime: Date(timeIntervalSince1970: 1_000),
            installation: CloudflaredInstallation(
                isInstalled: true,
                path: "/usr/local/bin/cloudflared",
                version: "2026.9.0"
            )
        )
        let quota = QuotaSnapshot(
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
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .ring,
            hideSensitiveInfo: true,
            modelAggregationMode: .average
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: true,
            tunnel: tunnel,
            directAuthProviders: [.antigravity, .claude],
            monitorAccounts: [enabledMonitorAccount, disabledMonitorAccount],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: "zulu@example.com",
            menuBarPreferences: preferences,
            appearanceMode: .dark,
            language: .vietnamese
        )

        XCTAssertFalse(snapshot.isLocalProxyMode)
        XCTAssertEqual(snapshot.proxyPort, 8317)
        XCTAssertTrue(snapshot.isProxyRunning)
        XCTAssertEqual(snapshot.tunnel, tunnel)
        XCTAssertEqual(snapshot.providers.map(\.provider), [.amp, .antigravity, .claude])
        XCTAssertTrue(snapshot.isLoadingQuotas)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayMode, .remaining)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayStyle, .ring)
        XCTAssertTrue(snapshot.displaySettings.hideSensitiveInfo)
        XCTAssertEqual(snapshot.displaySettings.modelAggregationMode, .average)
        XCTAssertEqual(snapshot.appearanceMode, .dark)
        XCTAssertEqual(snapshot.language, .vietnamese)

        let antigravity = try XCTUnwrap(snapshot.providers.first { $0.provider == .antigravity })
        XCTAssertTrue(antigravity.isRefreshing)
        XCTAssertTrue(antigravity.supportsScopedRefresh)
        XCTAssertEqual(antigravity.accounts.map(\.email), [
            "Zulu@example.com",
            "alpha@example.com",
        ])
        XCTAssertTrue(antigravity.accounts[0].isActiveInIDE)
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshing))
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshBlocked))
    }

    func testLocalProxySnapshotFiltersCLIProvidersByInstalledAgents() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .localProxy,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.antigravity, .claude, .codex],
            monitorAccounts: [],
            quota: QuotaSnapshot(),
            installedAgents: [.codexCLI],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english
        )

        XCTAssertTrue(snapshot.isLocalProxyMode)
        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .codex])
    }
}

@MainActor
final class StatusBarCommandDispatcherTests: XCTestCase {
    func testAsyncCommandsRouteAndRebuildAfterCompletion() async {
        let recorder = StatusBarCommandRecorder()
        let rebuilds = expectation(description: "menu rebuilt after async commands")
        rebuilds.expectedFulfillmentCount = 6
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
            rebuilds.fulfill()
        }

        dispatcher.dispatch(.refreshAll)
        dispatcher.dispatch(.refreshProvider(.claude))
        dispatcher.dispatch(.refreshAccount(QuotaAccountID(provider: .codex, accountKey: "person@example.com")))
        dispatcher.dispatch(.toggleProxy)
        dispatcher.dispatch(.toggleTunnel(port: 8317))
        dispatcher.dispatch(.useAntigravityAccount(email: "active@example.com"))

        await fulfillment(of: [rebuilds], timeout: 1)
        XCTAssertEqual(Set(recorder.asyncCommands), Set([
            "refreshAll",
            "refreshProvider:claude",
            "refreshAccount:codex:person@example.com",
            "toggleProxy",
            "toggleTunnel:8317",
            "switchAntigravity:active@example.com",
        ]))
        XCTAssertEqual(recorder.rebuildCount, 6)
    }

    func testSynchronousCommandsRouteWithoutUnnecessaryRebuilds() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.copyProxyURL("http://localhost:8317"))
        dispatcher.dispatch(.copyTunnelURL("https://example.trycloudflare.com"))
        dispatcher.dispatch(.openApp)
        dispatcher.dispatch(.quit)
        dispatcher.dispatch(.providerSelectionChanged)

        XCTAssertEqual(recorder.copiedText, [
            "http://localhost:8317",
            "https://example.trycloudflare.com",
        ])
        XCTAssertEqual(recorder.openAppCount, 1)
        XCTAssertEqual(recorder.quitCount, 1)
        XCTAssertEqual(recorder.rebuildCount, 1)
    }

    func testCancelledAntigravityConfirmationDoesNotSwitchOrRebuild() {
        let recorder = StatusBarCommandRecorder()
        recorder.confirmSwitch = false
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.useAntigravityAccount(email: "person@example.com"))

        XCTAssertEqual(recorder.ideRunningChecks, 1)
        XCTAssertEqual(recorder.confirmations, ["person@example.com:true"])
        XCTAssertTrue(recorder.asyncCommands.isEmpty)
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
            toggleProxy: { recorder.asyncCommands.append("toggleProxy") },
            toggleTunnel: { port in recorder.asyncCommands.append("toggleTunnel:\(port)") },
            copyText: { recorder.copiedText.append($0) },
            switchAntigravityAccount: { email in
                recorder.asyncCommands.append("switchAntigravity:\(email)")
            },
            isAntigravityIDERunning: {
                recorder.ideRunningChecks += 1
                return true
            },
            confirmAntigravitySwitch: { email, isRunning in
                recorder.confirmations.append("\(email):\(isRunning)")
                return recorder.confirmSwitch
            },
            openApp: { recorder.openAppCount += 1 },
            quit: { recorder.quitCount += 1 },
            menuNeedsRebuild: menuNeedsRebuild
        ))
    }
}

@MainActor
private final class StatusBarCommandRecorder {
    var asyncCommands: [String] = []
    var copiedText: [String] = []
    var confirmations: [String] = []
    var confirmSwitch = true
    var ideRunningChecks = 0
    var openAppCount = 0
    var quitCount = 0
    var rebuildCount = 0
}
