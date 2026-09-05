import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class AccountScreenModelsTests: XCTestCase {
    func testAccountsModelOwnsAccountAndAuthFileState() async {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: "codex"),
            accountKey: "person@example.com",
            source: .nativeCredential
        )
        let descriptor = AuthFileDescriptor(
            id: "auth-file",
            providerID: AccountProviderID(rawValue: "codex"),
            email: "person@example.com",
            login: nil,
            expired: nil,
            accountType: "plus",
            filePath: "/tmp/codex.json",
            source: .cliProxyApi,
            filename: "codex.json"
        )
        let model = AccountsScreenModel(
            accountService: AccountScreenModelService(accounts: [account]),
            authFileRepository: AccountScreenModelAuthFiles(files: [descriptor])
        )

        await model.reloadAccounts()
        await model.reloadAuthFiles()

        XCTAssertEqual(model.accounts, [account])
        XCTAssertEqual(model.authFiles, [descriptor])
        XCTAssertFalse(String(describing: model).contains("accessToken"))
    }

    func testAccountsModelReloadMergesQuotaDerivedAccounts() async {
        let model = AccountsScreenModel(
            accountService: AccountScreenModelService(accounts: []),
            authFileRepository: AccountScreenModelAuthFiles(files: [])
        )

        await model.reloadAccounts(merging: [
            .cursor: ["person@example.com": ProviderQuota(accountDisplayName: "Person")],
        ])

        XCTAssertEqual(model.accounts.map(\.accountKey), ["person@example.com"])
        XCTAssertEqual(model.accounts.first?.source, .localIDE)
    }

    func testQuotaAliasesDoNotCreateSyntheticDuplicateOfOwnedAccount() async throws {
        let owned = Account(
            identity: AccountIdentity(id: "vault-id", providerID: .init(rawValue: "codex"),
                accountKey: "same@example.com-pro"),
            displayName: "same@example.com", source: .quotioKeychain,
            credentialReference: "keychain", capabilities: [.disable, .delete], status: .disabled
        )
        let service = AccountScreenModelService(accounts: [owned])
        let model = AccountsScreenModel(accountService: service,
            authFileRepository: AccountScreenModelAuthFiles(files: []))

        await model.reloadAccounts(
            merging: [.codex: ["same@example.com": ProviderQuota()]],
            aliases: [.codex: ["same@example.com-pro": "same@example.com"]]
        )

        XCTAssertEqual(model.accounts.count, 1)
        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(account.accountKey, "same@example.com")
        XCTAssertEqual(account.id, owned.id)
        XCTAssertEqual(account.source, owned.source)
        XCTAssertEqual(account.credentialReference, owned.credentialReference)
        XCTAssertEqual(account.capabilities, owned.capabilities)
        XCTAssertTrue(account.isDisabled)
        await model.setDisabled(false, accountID: account.id)
        XCTAssertEqual(model.accounts.map(\.accountKey), ["same@example.com"])
        try await model.delete(accountID: account.id)
        let disabledID = await service.lastDisabledID
        let deletedID = await service.lastDeletedID
        XCTAssertEqual(disabledID, owned.id)
        XCTAssertEqual(deletedID, owned.id)
    }

    func testAliasesMergeSourcesButKeepDistinctWorkspaceAndOtherProvider() async {
        let provider = AccountProviderID(rawValue: "codex")
        let owned = Account.make(providerID: provider, accountKey: "same@example.com",
            source: .quotioKeychain, capabilities: [.disable, .delete])
        let legacy = Account.make(providerID: provider, accountKey: "same@example.com-pro",
            source: .legacyCLIProxy)
        let workspace = Account.make(providerID: provider, accountKey: "same@example.com-team",
            source: .legacyCLIProxy)
        let other = Account.make(providerID: .init(rawValue: "claude"),
            accountKey: "same@example.com-pro", source: .nativeCredential)
        let model = AccountsScreenModel(
            accountService: AccountScreenModelService(accounts: [legacy, owned, workspace, other]),
            authFileRepository: AccountScreenModelAuthFiles(files: []))

        await model.reloadAccounts(merging: [:],
            aliases: [.codex: ["same@example.com-pro": "same@example.com"]])

        XCTAssertEqual(Set(model.accounts.map(\.id)), [owned.id, workspace.id, other.id])
        await model.reloadAccounts()
        XCTAssertEqual(Set(model.accounts.map(\.id)), [owned.id, workspace.id, other.id])
    }

    func testDownloadEligibilityRequiresAnAuthFileName() {
        let authFileAccount = AccountRowData(
            id: "auth-file",
            provider: .claude,
            displayName: "person@example.com",
            authFileName: "claude-person@example.com.json",
            source: .direct,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: false
        )
        let customProviderAccount = AccountRowData(
            id: "custom-provider",
            provider: .glm,
            displayName: "GLM",
            source: .direct,
            status: "ready",
            statusMessage: nil,
            isDisabled: false,
            canDelete: true
        )

        XCTAssertTrue(authFileAccount.canDownloadAuthFile)
        XCTAssertFalse(customProviderAccount.canDownloadAuthFile)
    }

    func testOAuthModelPublishesSuccessAndRunsHandlerOnce() async {
        let providerID = AccountProviderID(rawValue: "claude")
        let controller = OAuthFlowController(authorizer: ImmediateOAuthAuthorizer())
        let model = OAuthScreenModel(controller: controller)
        var successCount = 0
        model.setSuccessHandler { successCount += 1 }

        await model.start(OAuthAuthorizationRequest(providerID: providerID))
        await waitUntil {
            if case .succeeded(let completedProvider, _) = model.state {
                return completedProvider == providerID
            }
            return false
        }

        XCTAssertEqual(successCount, 1)
        await model.shutdown()
        XCTAssertEqual(model.state, .idle)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor AccountScreenModelService: AccountManaging {
    private let storedAccounts: [Account]
    private(set) var lastDisabledID: String?
    private(set) var lastDeletedID: String?

    init(accounts: [Account]) {
        storedAccounts = accounts
    }

    func accounts() -> [Account] { storedAccounts }
    func setDisabled(_ disabled: Bool, accountID: String) { lastDisabledID = accountID }
    func delete(accountID: String) { lastDeletedID = accountID }

    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) {}
}

private actor AccountScreenModelAuthFiles: AuthFileRepository {
    private let files: [AuthFileDescriptor]

    init(files: [AuthFileDescriptor]) {
        self.files = files
    }

    func scanAllAuthFiles() -> [AuthFileDescriptor] { files }
    func readCredential(from file: AuthFileDescriptor) -> AuthFileCredential? { nil }
    func uploadAuthFile(name: String, content: Data) {}
    func readAuthFileForImport(from url: URL) -> Data { Data() }
    func writeDownloadedAuthFile(_ content: Data, to url: URL) {}
    func downloadAuthFile(name: String) -> Data { Data() }
}

private actor ImmediateOAuthAuthorizer: OAuthAuthorizing {
    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) -> OAuthAuthorizationOutcome {
        .completed(Account.make(
            providerID: request.providerID,
            accountKey: "person@example.com",
            source: .quotioKeychain,
            capabilities: [.disable, .delete]
        ))
    }

    func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) -> Account {
        Account.make(
            providerID: providerID,
            accountKey: "person@example.com",
            source: .quotioKeychain
        )
    }

    func cancel(attemptID: OAuthAttemptID) {}
}
