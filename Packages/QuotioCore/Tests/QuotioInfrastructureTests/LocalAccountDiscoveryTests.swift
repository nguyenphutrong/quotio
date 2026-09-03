import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class LocalAccountDiscoveryTests: XCTestCase {
    func testLegacyCodexAccountsUseDistinctFilenameKeysForSameEmail() {
        let plus = descriptor(
            id: "plus",
            provider: .codex,
            email: "same@example.com",
            filename: "codex-same@example.com-plus.json"
        )
        let team = descriptor(
            id: "team",
            provider: .codex,
            email: "same@example.com",
            filename: "codex-same@example.com-team.json"
        )

        let accounts = [plus, team].map(LocalAccountDiscovery.legacyAccount)

        XCTAssertEqual(
            Set(accounts.map(\.accountKey)),
            ["same@example.com-plus", "same@example.com-team"]
        )
        XCTAssertEqual(Set(accounts.map(\.deduplicationKey)).count, 2)
    }

    func testLegacyCopilotAccountPrefersLoginOverEmail() {
        let file = descriptor(
            id: "copilot",
            provider: .copilot,
            email: "person@example.com",
            login: "octocat",
            filename: "github-copilot-octocat.json"
        )

        let account = LocalAccountDiscovery.legacyAccount(file)

        XCTAssertEqual(account.accountKey, "octocat")
        XCTAssertEqual(account.displayName, "person@example.com")
    }

    func testNativeCodexAccountCanonicalizesByUniqueLegacyAccountID() {
        let native = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "same@example.com",
            source: .nativeCredential
        )

        let canonical = LocalAccountDiscovery.canonicalizeCodexAccount(
            native,
            accountID: "account-1",
            aliases: ["account-1": "same@example.com-pro"]
        )
        let distinct = LocalAccountDiscovery.canonicalizeCodexAccount(
            native,
            accountID: "account-2",
            aliases: ["account-1": "same@example.com-pro"]
        )

        XCTAssertEqual(canonical.accountKey, "same@example.com-pro")
        XCTAssertEqual(distinct.accountKey, "same@example.com")
    }

    private func descriptor(
        id: String,
        provider: QuotaProvider,
        email: String?,
        login: String? = nil,
        filename: String
    ) -> AuthFileDescriptor {
        AuthFileDescriptor(
            id: id,
            providerID: AccountProviderID(rawValue: provider.rawValue),
            email: email,
            login: login,
            expired: nil,
            accountType: nil,
            filePath: "/tmp/" + filename,
            source: .cliProxyApi,
            filename: filename
        )
    }
}
