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

    init(accounts: [Account]) {
        storedAccounts = accounts
    }

    func accounts() -> [Account] { storedAccounts }
    func setDisabled(_ disabled: Bool, accountID: String) {}
    func delete(accountID: String) {}

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
