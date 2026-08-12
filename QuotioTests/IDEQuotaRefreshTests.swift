import XCTest
@testable import Quotio

/// Covers the quota refresh applied to IDE-derived providers (Cursor, Trae) by the
/// global refresh actions — the path the menu bar "Refresh" uses (issues #163, #257).
final class IDEQuotaRefreshTests: XCTestCase {
    private func quota(_ percentage: Double, lastUpdated: Date) -> ProviderQuotaData {
        ProviderQuotaData(
            models: [ModelQuota(name: "cursor-fast", percentage: percentage, resetTime: "")],
            lastUpdated: lastUpdated
        )
    }

    /// The global refresh must actually update an imported Cursor account, instead of
    /// leaving the stale snapshot the menu bar was showing (issue #163).
    func testMergeImportedIDEQuotasUpdatesImportedAccount() {
        let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = quota(75, lastUpdated: Date(timeIntervalSince1970: 2_000))

        let merged = QuotaViewModel.mergeImportedIDEQuotas(
            fetched: ["user@example.com": fresh],
            into: ["user@example.com": stale]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["user@example.com"]?.models.first?.percentage, 75)
        XCTAssertEqual(merged["user@example.com"]?.lastUpdated, Date(timeIntervalSince1970: 2_000))
    }

    /// Guards the invariant introduced by the "delete imported Cursor/Trae account"
    /// fix (issue #213): a global refresh reads the IDE database, but it must never
    /// re-import an account key the user removed, or the account resurrects.
    func testMergeImportedIDEQuotasDoesNotResurrectDeletedAccount() {
        let kept = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = quota(80, lastUpdated: Date(timeIntervalSince1970: 2_000))
        let resurrected = quota(42, lastUpdated: Date(timeIntervalSince1970: 2_000))

        let merged = QuotaViewModel.mergeImportedIDEQuotas(
            fetched: ["kept@example.com": fresh, "deleted@example.com": resurrected],
            into: ["kept@example.com": kept]
        )

        XCTAssertNil(merged["deleted@example.com"], "Deleted IDE account must not be re-imported by a refresh")
        XCTAssertEqual(merged["kept@example.com"]?.models.first?.percentage, 80)
    }

    /// With nothing imported, a refresh must not pull accounts in: Cursor/Trae are
    /// import-on-explicit-scan only (issue #29).
    func testMergeImportedIDEQuotasImportsNothingWhenProviderNotScanned() {
        let merged = QuotaViewModel.mergeImportedIDEQuotas(
            fetched: ["user@example.com": quota(50, lastUpdated: Date())],
            into: [:]
        )

        XCTAssertTrue(merged.isEmpty, "A refresh must not import IDE accounts without an explicit scan")
    }

    /// A transiently unreadable IDE database must not wipe the imported account from
    /// the menu bar; the previous value stays until a scan removes it.
    func testMergeImportedIDEQuotasKeepsAccountMissingFromFetch() {
        let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))

        let merged = QuotaViewModel.mergeImportedIDEQuotas(fetched: [:], into: ["user@example.com": stale])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["user@example.com"]?.models.first?.percentage, 10)
    }

    /// The refresh path covers exactly the IDE-derived providers, which are also the
    /// ones excluded from the generic auto-detected re-import.
    func testIDEQuotaRefreshCoversBrowserAuthProviders() {
        XCTAssertEqual(QuotaViewModel.ideProvidersToSave, [.cursor, .trae])

        for provider in QuotaViewModel.ideProvidersToSave {
            XCTAssertTrue(provider.usesBrowserAuth, "\(provider.rawValue) is an IDE-derived provider")
            XCTAssertFalse(provider.supportsManualAuth, "\(provider.rawValue) cannot be added manually")
        }
    }
}
