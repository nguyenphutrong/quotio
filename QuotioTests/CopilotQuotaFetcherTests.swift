import XCTest
@testable import Quotio

final class CopilotQuotaFetcherTests: XCTestCase {
    // Issue #404: a single auth file (github-copilot-marcosvrs.json with
    // username "marcosvrs") must resolve to exactly one quota entry, with every
    // legacy key collapsing onto the canonical account key.
    func testSingleAuthFileCollapsesLegacyKeysIntoOneEntry() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-marcosvrs.json",
            username: "marcosvrs"
        )

        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "github-copilot-marcosvrs": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "marcosvrs": ProviderQuotaData(models: [], lastUpdated: freshDate),
            ],
            accounts: [identity]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, freshDate)
    }

    func testAccountIdentityPrefersUsernameOverFilenameSuffix() {
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-work.json",
            username: "marcosvrs"
        )

        XCTAssertEqual(identity.canonicalKey, "marcosvrs")
        XCTAssertEqual(
            Set(identity.aliases),
            ["github-copilot-work.json", "github-copilot-work", "work"]
        )
    }

    func testAccountIdentityFallsBackToFilenameSuffixWithoutUsername() {
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-marcosvrs.json",
            username: nil
        )

        XCTAssertEqual(identity.canonicalKey, "marcosvrs")
    }

    func testLegacyFilenameKeyMigratesWhenUsernameDiffersFromSuffix() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "github-copilot-work.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
            ],
            accounts: [
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-work.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, staleDate)
    }

    func testReconciliationPreservesNewerCanonicalQuota() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "marcosvrs": ProviderQuotaData(models: [], lastUpdated: freshDate),
                "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
            ],
            accounts: [
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-marcosvrs.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, freshDate)
    }

    func testReconciliationPromotesNewerLegacyQuota() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "marcosvrs": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: freshDate),
            ],
            accounts: [
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-marcosvrs.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, freshDate)
    }

    func testAliasMatchingAnotherAccountCanonicalKeyIsPreserved() {
        let date = Date(timeIntervalSince1970: 1_000)
        let quotas = [
            "marcosvrs": ProviderQuotaData(models: [], lastUpdated: date),
            "someone-else": ProviderQuotaData(models: [], lastUpdated: date),
        ]

        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: quotas,
            accounts: [
                // File whose suffix collides with another account's username.
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-marcosvrs.json",
                    username: "someone-else"
                ),
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-other.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs", "someone-else"])
    }

    func testAmbiguousAliasIsNotCollapsed() {
        let date = Date(timeIntervalSince1970: 1_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "shared-alias": ProviderQuotaData(models: [], lastUpdated: date),
            ],
            accounts: [
                CopilotQuotaAccountIdentity(canonicalKey: "first", aliases: ["shared-alias"]),
                CopilotQuotaAccountIdentity(canonicalKey: "second", aliases: ["shared-alias"]),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["shared-alias"])
    }

    func testDirectAuthFileMenuBarKeyIsCanonicalForUsernameField() {
        // ~/.cli-proxy-api/github-copilot-marcosvrs.json stores the GitHub
        // handle in "username"; DirectAuthFileService maps it to `login`.
        let file = DirectAuthFile(
            id: "/tmp/github-copilot-marcosvrs.json",
            provider: .copilot,
            email: nil,
            login: "marcosvrs",
            expired: nil,
            accountType: nil,
            filePath: "/tmp/github-copilot-marcosvrs.json",
            source: .cliProxyApi,
            filename: "github-copilot-marcosvrs.json"
        )

        XCTAssertEqual(file.menuBarAccountKey, "marcosvrs")
    }

    func testDirectAuthFileMenuBarKeyFallsBackToFilenameSuffix() {
        let file = DirectAuthFile(
            id: "/tmp/github-copilot-marcosvrs.json",
            provider: .copilot,
            email: nil,
            login: nil,
            expired: nil,
            accountType: nil,
            filePath: "/tmp/github-copilot-marcosvrs.json",
            source: .cliProxyApi,
            filename: "github-copilot-marcosvrs.json"
        )

        XCTAssertEqual(file.menuBarAccountKey, "marcosvrs")
    }
}
