import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testOverviewSeparatesFoundLoginsFromProvidersThatNeedSignIn() {
        let claude = account(.claude, key: "person@example.com")
        let pausedProviderAccount = account(.copilot, key: "paused@example.com")
        let factoryPermission = NativeSourcePermission(provider: .factoryDroid, kind: "factory_native", location: "v2_keyring")
        let pausedPermission = NativeSourcePermission(provider: .copilot, kind: "copilot_native", location: nil)

        let overview = OnboardingProviderOverview(
            providers: [
                descriptor(.claude, "Claude", ["start_oauth", "discover_native"]),
                descriptor(.codex, "Codex", ["discover_native"]),
                descriptor(.factoryDroid, "Factory Droid", ["add_api_key", "authorize_native", "discover_native"]),
                descriptor(.amp, "Amp", ["add_api_key"]),
                descriptor(.copilot, "Copilot", ["start_oauth", "authorize_native"]),
            ],
            accounts: [claude, pausedProviderAccount],
            permissions: [factoryPermission, pausedPermission],
            quota: QuotaSnapshot(accountStates: [
                QuotaAccountID(provider: .claude, accountKey: claude.accountKey):
                    AccountMonitoringState(connection: .connected, quota: .fresh),
            ]),
            tracking: ProviderTrackingPreferences(disabledProviders: [.copilot]),
            hasStorageProblem: false
        )

        XCTAssertEqual(overview.found.map(\.id), [.factoryDroid, .claude])
        XCTAssertEqual(overview.connectable.map(\.id), [.amp])
        XCTAssertEqual(overview.connectable.first?.supportsAPIKey, true)
        XCTAssertEqual(overview.connectable.first?.supportsBrowserSignIn, false)
        XCTAssertEqual(overview.pendingPermissions, [factoryPermission])
        XCTAssertTrue(overview.canAuthorize(factoryPermission))
        XCTAssertTrue(overview.needsAccess)
        XCTAssertEqual(overview.name(for: .factoryDroid), "Factory Droid")
    }

    func testOverviewRequiresAccessWhenAccountStoreIsLocked() {
        let overview = OnboardingProviderOverview(
            providers: [descriptor(.claude, "Claude", ["discover_native"])],
            accounts: [],
            permissions: [],
            quota: QuotaSnapshot(),
            tracking: ProviderTrackingPreferences(),
            hasStorageProblem: true
        )

        XCTAssertTrue(overview.found.isEmpty)
        XCTAssertTrue(overview.pendingPermissions.isEmpty)
        XCTAssertTrue(overview.needsAccess)
    }

    func testFoundProviderReportsFreshestQuotaAcrossAccounts() {
        let first = account(.codex, key: "one@example.com")
        let second = account(.codex, key: "two@example.com")
        let overview = OnboardingProviderOverview(
            providers: [descriptor(.codex, "Codex", ["discover_native"])],
            accounts: [first, second],
            permissions: [],
            quota: QuotaSnapshot(accountStates: [
                QuotaAccountID(provider: .codex, accountKey: first.accountKey):
                    AccountMonitoringState(connection: .connected, quota: .refreshing),
                QuotaAccountID(provider: .codex, accountKey: second.accountKey):
                    AccountMonitoringState(connection: .connected, quota: .fresh),
            ]),
            tracking: ProviderTrackingPreferences(),
            hasStorageProblem: false
        )

        XCTAssertEqual(overview.found.first?.accountCount, 2)
        XCTAssertEqual(overview.found.first?.quotaState, .fresh)
    }

    func testCompletionSummarySeparatesReadyLoadingAndAttentionProviders() {
        let codex = account(.codex, key: "ready@example.com")
        let claude = account(.claude, key: "loading@example.com")
        let amp = account(.amp, key: "failed@example.com")
        let factoryPermission = NativeSourcePermission(provider: .factoryDroid, kind: "factory_native", location: "legacy")
        let overview = OnboardingProviderOverview(
            providers: [
                descriptor(.codex, "Codex", ["discover_native"]),
                descriptor(.claude, "Claude", ["discover_native"]),
                descriptor(.amp, "Amp", ["add_api_key"]),
                descriptor(.factoryDroid, "Factory Droid", ["authorize_native"]),
            ],
            accounts: [codex, claude, amp],
            permissions: [factoryPermission],
            quota: QuotaSnapshot(accountStates: [
                QuotaAccountID(provider: .codex, accountKey: codex.accountKey):
                    AccountMonitoringState(connection: .connected, quota: .stale),
                QuotaAccountID(provider: .claude, accountKey: claude.accountKey):
                    AccountMonitoringState(connection: .connected, quota: .refreshing),
                QuotaAccountID(provider: .amp, accountKey: amp.accountKey):
                    AccountMonitoringState(connection: .connected, quota: .failed(nil)),
            ]),
            tracking: ProviderTrackingPreferences(),
            hasStorageProblem: false
        )

        XCTAssertEqual(overview.readyProviders.map(\.id), [.codex])
        XCTAssertEqual(overview.loadingProviders.map(\.id), [.claude])
        XCTAssertEqual(overview.attentionProviders.map(\.id), [.factoryDroid, .amp])
        XCTAssertEqual(overview.attentionProviders.map(\.issue), [.permissionRequired, .quotaFailed])
        XCTAssertNil(overview.attentionProviders.last?.connectionIssue)
    }

    func testFlowSkipsAccessStepWhenNothingNeedsPermission() {
        let model = OnboardingViewModel()

        XCTAssertEqual(model.progressSteps(needsAccess: false), [.connect, .finish])
        XCTAssertFalse(model.canGoBack(needsAccess: false))

        model.goNext(needsAccess: false)
        XCTAssertEqual(model.currentStep, .connect)
        model.goNext(needsAccess: false)
        XCTAssertEqual(model.currentStep, .finish)
        model.goNext(needsAccess: false)
        XCTAssertEqual(model.currentStep, .finish)

        model.goBack(needsAccess: false)
        XCTAssertEqual(model.currentStep, .connect)
        XCTAssertEqual(model.direction, .backward)
    }

    func testAccessStepStaysVisibleAfterUserGrantsEveryRequest() {
        let model = OnboardingViewModel()
        model.goNext(needsAccess: true)
        model.goNext(needsAccess: true)
        XCTAssertEqual(model.currentStep, .access)

        XCTAssertEqual(model.progressSteps(needsAccess: false), [.connect, .access, .finish])
        model.goNext(needsAccess: false)
        XCTAssertEqual(model.currentStep, .finish)
        model.goBack(needsAccess: false)
        XCTAssertEqual(model.currentStep, .access)
    }

    private func descriptor(_ provider: QuotaProvider, _ name: String, _ actions: Set<String>) -> MonitoringProvider {
        MonitoringProvider(id: provider, displayName: name, actions: actions, inputs: [])
    }

    private func account(_ provider: QuotaProvider, key: String) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: key,
            source: .nativeCredential
        )
    }
}
