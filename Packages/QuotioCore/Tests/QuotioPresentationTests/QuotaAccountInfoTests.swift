import XCTest
import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class QuotaAccountInfoTests: XCTestCase {
    func testMergesDisabledProxyAliasWithDirectQuotaWithoutChangingProxyStatus() throws {
        let file = authFile("same@example.com-pro", disabled: true)
        let quota = ProviderQuota(lastUpdated: Date())
        let rows = AccountInfo.merged(
            provider: .codex, authFiles: [file],
            quotaData: ["same@example.com": quota], subscriptionInfos: [:],
            directAccounts: [], aliases: ["same@example.com-pro": "same@example.com"]
        )
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.key, "same@example.com")
        XCTAssertEqual(row.quotaData, quota)
        XCTAssertEqual(row.authFile, file)
        XCTAssertEqual(row.status, "disabled")
    }

    func testSameEmailWithDifferentKeysRemainsSeparateWithoutIdentityAlias() {
        let rows = AccountInfo.merged(
            provider: .codex,
            authFiles: [authFile("same@example.com-pro"), authFile("same@example.com-team")],
            quotaData: [:], subscriptionInfos: [:], directAccounts: [], aliases: [:]
        )
        XCTAssertEqual(Set(rows.map(\.key)), ["same@example.com-pro", "same@example.com-team"])
    }

    func testMultipleAuthAliasesProduceOneCardAndKeepMissingQuotaStatus() {
        let rows = AccountInfo.merged(
            provider: .codex,
            authFiles: [authFile("same@example.com-pro"), authFile("same@example.com")],
            quotaData: [:], subscriptionInfos: [:], directAccounts: [],
            aliases: ["same@example.com-pro": "same@example.com"]
        )
        XCTAssertEqual(rows.map(\.key), ["same@example.com"])
        XCTAssertNil(rows.first?.quotaData)
        XCTAssertNotNil(rows.first?.authFile)
    }

    private func authFile(_ key: String, disabled: Bool = false) -> ManagedAuthFile {
        ManagedAuthFile(
            id: key, name: "codex-\(key).json", provider: "codex",
            status: disabled ? "disabled" : "active", disabled: disabled,
            unavailable: false, email: "same@example.com"
        )
    }
}
