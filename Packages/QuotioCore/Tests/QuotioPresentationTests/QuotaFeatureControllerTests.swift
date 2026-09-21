import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class QuotaFeatureControllerTests: XCTestCase {
    func testAutomaticRefreshProvidersPreserveOperatingModeBehavior() {
        XCTAssertEqual(
            QuotaFeatureController.automaticallyRefreshedProviders(for: .localProxy),
            [.antigravity, .vertex, .codex, .copilot, .claude, .glm, .warp, .kiro, .clinePass]
        )
        XCTAssertEqual(
            QuotaFeatureController.automaticallyRefreshedProviders(for: .monitor),
            [
                .codex, .claude, .copilot, .kiro, .glm, .clinePass, .warp,
                .antigravity, .vertex, .factoryDroid, .devin, .grok, .openRouter, .amp,
            ]
        )
    }

    func testRefreshRemovesQuotaForDisabledNativeAccount() async {
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

        XCTAssertNil(fixture.quota.providerQuotas[.kiro])
        await fixture.controller.shutdown()
    }

    func testRemoveImportedIDEAccountClearsDisabledMetadataWithoutDeletingCredential() async {
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
        XCTAssertEqual(disabledUpdates, [
            QuotaFeatureAccountService.DisabledUpdate(accountID: account.id, disabled: false),
        ])
        XCTAssertEqual(deletedAccountIDs, [])
        XCTAssertNil(fixture.quota.providerQuotas[.cursor]?[account.accountKey])
        await fixture.controller.shutdown()
    }

    func testRemoveOwnedAccountDeletesCredentialBeforeRemovingQuota() async {
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
        XCTAssertNil(fixture.quota.providerQuotas[.openRouter]?[account.accountKey])
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
        XCTAssertEqual(fixture.menuBar.selectedItems, [canonical])
        XCTAssertTrue(fixture.menuBar.hasUserModifiedMenuBar)
        await fixture.controller.shutdown()
    }

    func testDisabledProxyFilesCannotReenterMenuThroughFileFallback() async {
        let account = Account.make(providerID: AccountProviderID(rawValue: "claude"), accountKey: "Personal", source: .quotioKeychain)
        let disabled = AuthFileDescriptor(
            id: "proxy", providerID: AccountProviderID(rawValue: "claude"), email: "Work",
            login: nil, expired: nil, accountType: nil, filePath: "/test/claude-work.json",
            source: .cliProxyApi, filename: "claude-work.json"
        )
        let fixture = await makeFixture(account: account, provider: .claude, authFiles: [disabled], disabledFiles: [disabled.filename])
        // Live data can briefly lag a successful disable; persisted state must win.
        fixture.controller.setAuthFilesProvider {
            [ManagedAuthFile(id: "proxy", name: disabled.filename, provider: "claude", status: "ready", disabled: false, unavailable: false, email: "Work")]
        }
        fixture.menuBar.selectedItems = [MenuBarQuotaItem(provider: "claude", accountKey: "Work")]
        fixture.controller.synchronizeMenuBarSelection()
        XCTAssertFalse(fixture.menuBar.selectedItems.contains { $0.accountKey == "Work" })

        let sameName = await makeFixture(
            account: Account.make(providerID: AccountProviderID(rawValue: "claude"), accountKey: "Work", source: .quotioKeychain),
            provider: .claude, authFiles: [disabled], disabledFiles: [disabled.filename]
        )
        sameName.menuBar.selectedItems = [MenuBarQuotaItem(provider: "claude", accountKey: "Work")]
        sameName.controller.synchronizeMenuBarSelection()
        XCTAssertEqual(sameName.menuBar.selectedItems, [MenuBarQuotaItem(provider: "claude", accountKey: "Work")])
        await fixture.controller.shutdown()
        await sameName.controller.shutdown()
    }

    private func makeFixture(
        account: Account,
        provider: QuotaProvider,
        quotaAccountKey: String? = nil,
        aliases: [String: String] = [:],
        authFiles: [AuthFileDescriptor] = [],
        disabledFiles: Set<String> = []
    ) async -> (
        controller: QuotaFeatureController,
        accountService: QuotaFeatureAccountService,
        quota: QuotaScreenModel,
        menuBar: MenuBarSettingsManager
    ) {
        let accountService = QuotaFeatureAccountService(accounts: [account])
        let accounts = AccountsScreenModel(
            accountService: accountService,
            authFileRepository: QuotaFeatureAuthFileRepository(files: authFiles)
        )
        let quota = QuotaScreenModel(coordinator: TestQuotaCoordinator(
            snapshot: QuotaSnapshot(
                quotas: [
                provider: [
                    quotaAccountKey ?? account.accountKey: ProviderQuota(
                        lastUpdated: Date(timeIntervalSince1970: 1_000)
                    ),
                ],
                ],
                accountAliases: aliases.isEmpty ? [:] : [provider: aliases]
            )
        ))
        await quota.bootstrap(mode: .monitor)
        await accounts.reloadAccounts()
        await accounts.reloadAuthFiles()
        let preferences = QuotaFeaturePreferencesRepository()
        let menuBar = MenuBarSettingsManager(repository: preferences)
        let controller = QuotaFeatureController(
            quota: quota,
            accounts: accounts,
            oauth: OAuthScreenModel(controller: OAuthFlowController(authorizer: QuotaFeatureOAuthAuthorizer())),
            antigravityAccounts: AntigravityAccountScreenModel(switcher: QuotaFeatureAntigravitySwitcher()),
            modeManager: OperatingModeManager(repository: preferences),
            refreshSettings: RefreshSettingsManager(repository: preferences),
            menuBarSettings: menuBar,
            notifications: NotificationController(
                repository: preferences,
                delivery: QuotaFeatureNotificationDelivery()
            ),
            authFiles: { [] },
            authFileState: QuotaFeatureAuthFileState(names: disabledFiles)
        )
        return (controller, accountService, quota, menuBar)
    }
}

private actor QuotaFeatureAntigravitySwitcher: AntigravityAccountSwitching {
    func snapshots() -> AsyncStream<AntigravitySwitchSnapshot> {
        AsyncStream { continuation in
            continuation.yield(AntigravitySwitchSnapshot())
            continuation.finish()
        }
    }

    func snapshot() -> AntigravitySwitchSnapshot { AntigravitySwitchSnapshot() }
    func isAvailable() -> Bool { false }
    func isIDERunning() -> Bool { false }
    func detectActiveAccount() -> AntigravityActiveAccount? { nil }
    func switchAccount(email: String, authDirectory: String, restartIDE: Bool) {}
    func switchAccount(authFilePath: String, restartIDE: Bool) {}
    func cancelSwitch() {}
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

    init(accounts: [Account]) {
        storedAccounts = accounts
    }

    func accounts() -> [Account] { storedAccounts }

    func setDisabled(_ disabled: Bool, accountID: String) {
        recordedDisabledUpdates.append(DisabledUpdate(accountID: accountID, disabled: disabled))
    }

    func delete(accountID: String) {
        recordedDeletedAccountIDs.append(accountID)
        storedAccounts.removeAll { $0.id == accountID }
    }

    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) {}

    func disabledUpdates() -> [DisabledUpdate] { recordedDisabledUpdates }
    func deletedAccountIDs() -> [String] { recordedDeletedAccountIDs }
}

private actor QuotaFeatureAuthFileRepository: AuthFileRepository {
    let files: [AuthFileDescriptor]
    init(files: [AuthFileDescriptor] = []) { self.files = files }
    func scanAllAuthFiles() -> [AuthFileDescriptor] { files }
    func readCredential(from file: AuthFileDescriptor) -> AuthFileCredential? { nil }
    func uploadAuthFile(name: String, content: Data) {}
    func readAuthFileForImport(from url: URL) -> Data { Data() }
    func writeDownloadedAuthFile(_ content: Data, to url: URL) {}
    func downloadAuthFile(name: String) -> Data { Data() }
}

private actor QuotaFeatureOAuthAuthorizer: OAuthAuthorizing {
    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
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

private struct QuotaFeatureAuthFileState: ManagedAuthFileStateRepository {
    let names: Set<String>
    func disabledAuthFileNames() -> Set<String> { names }
    func saveDisabledAuthFileNames(_ names: Set<String>) {}
    func recordAuthFilesChanged(at date: Date) {}
}
