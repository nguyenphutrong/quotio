import Foundation
import QuotioApplication
import QuotioDomain
import QuotioPresentation
import XCTest

@testable import Quotio

@MainActor
final class QuotaFeatureControllerTests: XCTestCase {
    func testAutomaticRefreshProvidersPreserveOperatingModeBehavior() {
        XCTAssertEqual(
            QuotaFeatureController.automaticallyRefreshedProviders(for: .localProxy),
            [.antigravity, .codex, .copilot, .claude, .glm, .warp, .kiro, .clinePass]
        )
        XCTAssertEqual(
            QuotaFeatureController.automaticallyRefreshedProviders(for: .monitor),
            [
                .codex, .claude, .copilot, .kiro, .glm, .clinePass, .warp,
                .antigravity, .factoryDroid, .devin, .grok, .openRouter, .amp,
            ]
        )
    }

    func testRemoveImportedIDEAccountClearsDisabledMetadataWithoutDeletingCredential() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: AIProvider.cursor.rawValue),
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
            providerID: AccountProviderID(rawValue: AIProvider.openRouter.rawValue),
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

    private func makeFixture(
        account: Account,
        provider: AIProvider
    ) async -> (
        controller: QuotaFeatureController,
        accountService: QuotaFeatureAccountService,
        quota: QuotaScreenModel
    ) {
        let accountService = QuotaFeatureAccountService(accounts: [account])
        let accounts = AccountsScreenModel(
            accountService: accountService,
            authFileRepository: QuotaFeatureAuthFileRepository()
        )
        let quota = QuotaScreenModel(coordinator: QuotaRefreshCoordinator(
            registry: QuotaProviderRegistry([]),
            snapshots: QuotaFeatureSnapshotStore(initial: QuotaSnapshot(quotas: [
                provider: [account.accountKey: ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))],
            ])),
            clock: QuotaFeatureClock()
        ))
        await quota.bootstrap(mode: .monitor)
        await accounts.reloadAccounts()
        let preferences = QuotaFeaturePreferencesRepository()
        let controller = QuotaFeatureController(
            quota: quota,
            accounts: accounts,
            oauth: OAuthScreenModel(controller: OAuthFlowController(authorizer: QuotaFeatureOAuthAuthorizer())),
            antigravityAccounts: AntigravityAccountScreenModel(switcher: .shared),
            modeManager: OperatingModeManager(repository: preferences),
            refreshSettings: RefreshSettingsManager(repository: preferences),
            menuBarSettings: MenuBarSettingsManager(repository: preferences),
            notifications: NotificationController(
                repository: preferences,
                delivery: QuotaFeatureNotificationDelivery()
            ),
            authFiles: { [] }
        )
        return (controller, accountService, quota)
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
    func scanAllAuthFiles() -> [AuthFileDescriptor] { [] }
    func readCredential(from file: AuthFileDescriptor) -> AuthFileCredential? { nil }
    func uploadAuthFile(name: String, content: Data) {}
    func readAuthFileForImport(from url: URL) -> Data { Data() }
    func writeDownloadedAuthFile(_ content: Data, to url: URL) {}
    func downloadAuthFile(name: String) -> Data { Data() }
}

private actor QuotaFeatureSnapshotStore: QuotaSnapshotStoring {
    private let initial: QuotaSnapshot

    init(initial: QuotaSnapshot) {
        self.initial = initial
    }

    func load(for mode: QuotaOperatingMode) -> QuotaSnapshot { initial }
    func save(_ snapshot: QuotaSnapshot, for mode: QuotaOperatingMode) {}
}

private struct QuotaFeatureClock: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 2_000) }
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
