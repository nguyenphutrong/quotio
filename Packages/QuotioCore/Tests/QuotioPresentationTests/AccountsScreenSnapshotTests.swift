import AppKit
import Foundation
import QuotioApplication
import QuotioDomain
import SwiftUI
import XCTest

@testable import QuotioPresentation

/// Renders the Accounts screen into PNGs for manual visual review. Only runs when
/// QUOTIO_ACCOUNTS_SNAPSHOT_DIR points at an output directory; skipped otherwise.
/// Vietnamese and English text come from the built Quotio.app string catalogs.
@MainActor
final class AccountsScreenSnapshotTests: XCTestCase {
    func testRenderAccountsScreenScenarios() async throws {
        guard let output = ProcessInfo.processInfo.environment["QUOTIO_ACCOUNTS_SNAPSHOT_DIR"], !output.isEmpty else {
            throw XCTSkip("Set QUOTIO_ACCOUNTS_SNAPSHOT_DIR to render snapshots")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let fixture = SnapshotFixture()
        await fixture.controller.initialize()
        XCTAssertTrue(fixture.controller.trackingPreferences.isEnabled(.claude))
        XCTAssertFalse(fixture.controller.trackingPreferences.isEnabled(.cursor))

        let full: [(String, NSAppearance.Name, CGFloat)] = [
            ("en", .aqua, 800), ("en", .darkAqua, 800),
            ("vi", .aqua, 800), ("vi", .aqua, 480), ("vi", .darkAqua, 480), ("en", .darkAqua, 480),
        ]
        for (language, appearance, width) in full {
            useLanguage(language)
            let view = fixture.environment(AccountsSettingsScreen())
            try await render(view, width: width, height: 1000, appearance: appearance,
                to: output + "/accounts-full-\(language)-\(appearance == .darkAqua ? "dark" : "light")-\(Int(width)).png")
        }

        useLanguage("vi")
        let unconnectedView = fixture.environment(
            Form {
                Section {
                    DisclosureGroup(isExpanded: .constant(true)) {
                        ForEach([QuotaProvider.amp, .copilot, .kiro, .glm, .vertex], id: \.self) {
                            UnconnectedProviderRow(provider: $0)
                        }
                    } label: {
                        Text(String(format: "settings.unconnectedCount".localized(), 5))
                    }
                }
            }
            .formStyle(.grouped)
        )
        try await render(unconnectedView, width: 800, height: 300, appearance: .aqua,
            to: output + "/accounts-unconnected-vi-light-800.png")

        let claudeState = ProviderSettingsState(provider: .claude, accounts: fixture.accountService.storedAccounts,
            permissions: [], quota: fixture.quota.state, tracking: fixture.controller.trackingPreferences)
        for (language, appearance) in [("en", NSAppearance.Name.aqua), ("vi", .darkAqua)] {
            useLanguage(language)
            let view = fixture.environment(
                Form {
                    ProviderAccountsSection(state: claudeState, visibleAccounts: claudeState.accounts)
                }
                .formStyle(.grouped)
                .environment(AccountsSettingsScreenModel())
            )
            try await render(view, width: 800, height: 460, appearance: appearance,
                to: output + "/accounts-detail-\(language)-\(appearance == .darkAqua ? "dark" : "light")-800.png")
        }
        await fixture.controller.shutdown()
    }

    private func useLanguage(_ code: String) {
        let appPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/macos/build/DebugDerivedData/Build/Products/Debug/Quotio.app")
        guard let app = Bundle(url: appPath),
              let path = app.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return }
        PresentationLocalization.updateBundle(bundle)
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat,
                                 appearance: NSAppearance.Name, to path: String) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("No bitmap for \(path)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("No PNG for \(path)")
            return
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
private final class SnapshotFixture {
    let navigation = NavigationScreenModel()
    let accounts: AccountsScreenModel
    let quota: QuotaScreenModel
    let controller: QuotaFeatureController
    let menuBar: MenuBarSettingsManager
    let accountService: SnapshotAccountService

    init() {
        let now = Date()
        func source(_ id: String, _ kind: AccountSource, _ ref: String?, _ location: String? = nil,
                    status: AccountStatus = .ready, enabled: Bool? = nil) -> AccountLoginSource {
            AccountLoginSource(accountID: id, source: kind, credentialReference: ref, status: status,
                location: location, enabled: enabled, actions: ["set_source_enabled", "remove_source"])
        }
        func account(_ provider: String, _ key: String, _ name: String? = nil,
                     sources: [AccountLoginSource], disabled: Bool = false, verified: Bool? = nil) -> Account {
            Account(identity: .make(providerID: .init(rawValue: provider), accountKey: key),
                displayName: name ?? key, source: sources.first?.source ?? .nativeCredential,
                enabled: !disabled, sources: sources, isIdentityVerified: verified)
        }

        let work = account("claude", "work@company-with-a-very-long-domain-name.com", sources: [
            source("claude-work-code", .nativeCredential, "claude_native", "code_keychain"),
            source("claude-work-vault", .quotioKeychain, nil),
        ], verified: true)
        let personal = account("claude", "personal@gmail.com", sources: [
            source("claude-personal-code", .nativeCredential, "claude_native", "code_file"),
        ], verified: true)
        let team = account("claude", "team-api-key", "team-api-key", sources: [
            source("claude-team-key", .apiKey, nil),
        ], disabled: true, verified: true)
        let codexDev = account("codex", "dev@example.com", sources: [
            source("codex-dev-file", .nativeCredential, "codex_native", "default"),
        ], verified: true)
        let cursorMain = account("cursor", "cursor-main", sources: [
            source("cursor-main-file", .localIDE, "cursor_native"),
        ], verified: true)
        let cursorSecond = account("cursor", "cursor-second-long-account-name@example.org", sources: [
            source("cursor-second-file", .localIDE, "cursor_native"),
        ], verified: true)
        let antigravityUnidentified = account("antigravity", "antigravity:native", "Antigravity", sources: [
            source("antigravity-native", .nativeCredential, "antigravity_native", "gemini_keychain"),
        ], verified: false)

        let factoryPermission = NativeSourcePermission(provider: .factoryDroid, kind: "factory_native",
            location: "v2_login_keychain", keychainAccount: "factory")
        let service = SnapshotAccountService(
            accounts: [work, personal, team, codexDev, cursorMain, cursorSecond, antigravityUnidentified],
            discovery: NativeDiscoverySnapshot(
                permissions: [factoryPermission],
                scannedAt: [.claude: now.addingTimeInterval(-3600), .factoryDroid: now.addingTimeInterval(-7200)],
                failedProviders: [.kiro]),
            storageProblem: .requiresAuthorization)
        accountService = service
        accounts = AccountsScreenModel(accountService: service)

        func totals(_ percent: Double) -> QuotaSummary {
            QuotaSummary(sessionOnly: .init(lowest: percent, average: percent),
                combined: .init(lowest: percent, average: percent), pair: [])
        }
        func id(_ provider: QuotaProvider, _ account: Account) -> QuotaAccountID {
            QuotaAccountID(provider: provider, accountKey: account.accountKey)
        }
        let snapshot = QuotaSnapshot(
            hostID: "host",
            canRefresh: true,
            canManageSettings: true,
            accountStates: [
                id(.claude, work): .init(connection: .connected, quota: .fresh),
                id(.claude, personal): .init(connection: .reauthenticationRequired, quota: .failed(.authentication)),
                id(.claude, team): .init(connection: .disabled, quota: .notLoaded),
                id(.codex, codexDev): .init(connection: .connected, quota: .stale),
                id(.antigravity, antigravityUnidentified): .init(connection: .reauthenticationRequired, quota: .failed(.authentication)),
            ],
            quotas: [
                .claude: [work.accountKey: ProviderQuota(lastUpdated: now.addingTimeInterval(-120), planType: "Max", summary: totals(64))],
                .codex: [codexDev.accountKey: ProviderQuota(lastUpdated: now.addingTimeInterval(-87_000), summary: totals(12))],
            ],
            accountIDs: [.claude: [work.accountKey: "claude-work-code"]],
            accountIssues: [
                id(.claude, personal): .init(kind: .failed, occurredAt: now.addingTimeInterval(-300),
                    reason: .authentication, recoveryAction: .signIn),
            ],
            lastUpdated: now.addingTimeInterval(-120))
        quota = QuotaScreenModel(coordinator: TestQuotaCoordinator(snapshot: snapshot))

        let preferences = SnapshotPreferences()
        menuBar = MenuBarSettingsManager(repository: preferences)
        menuBar.addItem(MenuBarQuotaItem(provider: "claude", accountKey: work.accountKey, hostID: "host"))
        controller = QuotaFeatureController(
            quota: quota,
            accounts: accounts,
            oauth: OAuthScreenModel(controller: OAuthFlowController(authorizer: SnapshotOAuthAuthorizer())),
            modeManager: OperatingModeManager(repository: preferences),
            monitoringSettings: SnapshotMonitoringSettings(),
            menuBarSettings: menuBar,
            notifications: NotificationController(repository: preferences, delivery: SnapshotNotificationDelivery()))
    }

    func environment<V: View>(_ view: V) -> some View {
        view
            .environment(navigation)
            .environment(accounts)
            .environment(quota)
            .environment(controller)
            .environment(menuBar)
            .environment(ProviderImageScreenModel { _, _ in nil })
    }
}

private actor SnapshotAccountService: AccountManaging {
    let storedAccounts: [Account]
    private let discovery: NativeDiscoverySnapshot
    private let storageProblem: AccountStorageProblem?

    init(accounts: [Account], discovery: NativeDiscoverySnapshot, storageProblem: AccountStorageProblem?) {
        storedAccounts = accounts
        self.discovery = discovery
        self.storageProblem = storageProblem
    }

    func registerDetectedNativeAccounts() {}
    func rescanNativeAccounts(for provider: QuotaProvider) {}
    func nativeDiscoverySnapshot() -> NativeDiscoverySnapshot { discovery }
    func authorizeNativeSource(_ source: NativeSourcePermission) {}
    func accountStorageProblem() -> AccountStorageProblem? { storageProblem }
    func accounts() -> [Account] { storedAccounts }
    func setDisabled(_ disabled: Bool, accountID: String) {}
    func delete(accountID: String) throws {}
    func renameResolvedAccount(id: String, userLabel: String?) throws {}
    func setSourceEnabled(_ enabled: Bool, sourceID: String) throws {}
    func unlinkSource(sourceID: String) throws {}
    func saveAPIKey(providerID: AccountProviderID, label: String, apiKey: String,
                    existingAccountID: String?, fields: [String: String]) throws {}
}

private actor SnapshotMonitoringSettings: MonitoringSettingsManaging {
    func monitoringProviders() -> [MonitoringProvider] {
        func descriptor(_ provider: QuotaProvider, _ actions: Set<String>) -> MonitoringProvider {
            MonitoringProvider(id: provider, displayName: provider.displayName, actions: actions, inputs: [])
        }
        return [
            descriptor(.claude, ["start_oauth", "discover_native", "authorize_native"]),
            descriptor(.codex, ["start_oauth", "discover_native"]),
            descriptor(.cursor, ["add_api_key"]),
            descriptor(.factoryDroid, ["discover_native", "authorize_native"]),
            descriptor(.antigravity, ["start_oauth", "discover_native", "authorize_native"]),
            descriptor(.copilot, ["start_oauth", "discover_native"]),
            descriptor(.kiro, ["start_oauth", "discover_native"]),
            descriptor(.amp, ["add_api_key", "discover_native"]),
            descriptor(.glm, ["add_api_key"]),
            descriptor(.qwen, ["start_oauth"]),
            descriptor(.vertex, []),
        ]
    }

    func monitoringSettings() -> MonitoringSettings {
        MonitoringSettings(revision: "snapshot",
            enabledProviders: Set(QuotaProvider.allCases.map(\.rawValue)).subtracting(["cursor"]),
            disabledProviders: ["cursor"], automaticallyDiscoverLogins: true, refreshInterval: 600)
    }

    func updateMonitoringSettings(_ settings: MonitoringSettings) -> MonitoringSettings { settings }
}

private actor SnapshotOAuthAuthorizer: OAuthAuthorizing {
    func begin(request: OAuthAuthorizationRequest, attemptID: OAuthAttemptID,
               progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void) async throws -> OAuthAuthorizationOutcome {
        throw OAuthFlowFailure.unsupportedProvider
    }

    func completeManualCode(_ code: String, providerID: AccountProviderID, attemptID: OAuthAttemptID) async throws -> Account {
        throw OAuthFlowFailure.unsupportedProvider
    }

    func cancel(attemptID: OAuthAttemptID) async {}
}

@MainActor
private final class SnapshotNotificationDelivery: NotificationDelivering {
    func requestAuthorization() async -> NotificationAuthorizationStatus { .denied }
    func authorizationStatus() async -> NotificationAuthorizationStatus { .denied }
    func deliver(_ notification: SemanticNotification) {}
    func removeAllPending() {}
    func removeAllDelivered() {}
}

private final class SnapshotPreferences:
    OperatingModePreferencesRepository,
    RefreshPreferencesRepository,
    MenuBarPreferencesRepository,
    NotificationPreferencesRepository,
    @unchecked Sendable
{
    func load() -> OperatingModePreferences { OperatingModePreferences(mode: .monitor, hasCompletedOnboarding: true) }
    func save(_ preferences: OperatingModePreferences) {}
    func load() -> RefreshPreferences { RefreshPreferences(cadence: .manual) }
    func save(_ preferences: RefreshPreferences) {}
    func load() -> MenuBarPreferences { MenuBarPreferences() }
    func save(_ preferences: MenuBarPreferences) {}
    func load() -> NotificationPreferences { NotificationPreferences(notificationsEnabled: false) }
    func save(_ preferences: NotificationPreferences) {}
}
