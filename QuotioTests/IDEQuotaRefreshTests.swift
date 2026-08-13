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

/// A gate a test can suspend the injected IDE fetch on, so the interleaved main-actor
/// work (a deletion, a competing refresh) happens exactly while the fetch is in flight.
@MainActor
private final class IDEFetchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Exercises the *reentrant* behaviour of `refreshImportedIDEQuotas()`.
///
/// `QuotaViewModel` is `@MainActor`, which serialises its state but does **not** make a
/// method atomic: every `await` is a suspension point at which other main-actor work
/// runs. These tests suspend inside the IDE fetch, mutate the view model from the test
/// body (i.e. exactly as a user action would), resume, and assert the refresh honours
/// the state as it is at write time rather than the snapshot it took before the await.
final class IDEQuotaRefreshReentrancyTests: XCTestCase {
    private static let persistedIDEQuotasKey = "persisted.ideQuotas"

    private func quota(_ percentage: Double, lastUpdated: Date) -> ProviderQuotaData {
        ProviderQuotaData(
            models: [ModelQuota(name: "cursor-fast", percentage: percentage, resetTime: "")],
            lastUpdated: lastUpdated
        )
    }

    /// The refresh persists to `UserDefaults.standard`; keep the developer's real data.
    private func withPersistedIDEQuotasRestored(_ body: () async -> Void) async {
        let saved = UserDefaults.standard.data(forKey: Self.persistedIDEQuotasKey)
        await body()
        if let saved {
            UserDefaults.standard.set(saved, forKey: Self.persistedIDEQuotasKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.persistedIDEQuotasKey)
        }
    }

    private func persistedIDEQuotas() -> [String: [String: ProviderQuotaData]] {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedIDEQuotasKey),
              let decoded = try? JSONDecoder().decode(
                  [String: [String: ProviderQuotaData]].self, from: data
              ) else { return [:] }
        return decoded
    }

    /// The regression the review called out: an account deleted (issue #213 / PR #472)
    /// while the IDE fetch is suspended must not be restored by the write that follows.
    /// A pre-await snapshot of `providerQuotas` would resurrect it — both in memory and
    /// in the persisted snapshot the next launch reads.
    @MainActor
    func testGlobalRefreshDoesNotResurrectAccountDeletedWhileFetchIsSuspended() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let kept = "kept@example.com"
            let deleted = "deleted@example.com"
            let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
            let fresh = quota(75, lastUpdated: Date(timeIntervalSince1970: 2_000))

            viewModel.providerQuotas = [.cursor: [kept: stale, deleted: stale]]

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            viewModel.ideQuotaFetchHookForTesting = { provider in
                guard provider == .cursor else { return [:] }
                suspendedInFetch.fulfill()
                await gate.wait()
                // The IDE database still knows about both accounts.
                return [kept: fresh, deleted: fresh]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)

            // Reentrant main-actor work: the user deletes the imported account while the
            // fetch is still awaiting.
            viewModel.providerQuotas[.cursor]?.removeValue(forKey: deleted)

            gate.open()
            await refresh.value

            XCTAssertNil(
                viewModel.providerQuotas[.cursor]?[deleted],
                "An account deleted during the fetch must not be restored from the pre-await snapshot"
            )
            XCTAssertNil(
                persistedIDEQuotas()[AIProvider.cursor.rawValue]?[deleted],
                "The resurrected account must not reach the persisted snapshot either"
            )
            XCTAssertEqual(
                viewModel.providerQuotas[.cursor]?[kept]?.models.first?.percentage,
                75,
                "The surviving account still receives the fresh quota (issue #163)"
            )
        }
    }

    /// The whole provider disappearing mid-fetch (the last imported account deleted) must
    /// not re-create the provider entry from the snapshot taken before the await.
    @MainActor
    func testGlobalRefreshDoesNotRestoreProviderRemovedWhileFetchIsSuspended() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let account = "only@example.com"
            viewModel.providerQuotas = [
                .cursor: [account: quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))]
            ]

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            viewModel.ideQuotaFetchHookForTesting = { _ in
                suspendedInFetch.fulfill()
                await gate.wait()
                return [account: self.quota(90, lastUpdated: Date(timeIntervalSince1970: 2_000))]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)

            viewModel.providerQuotas.removeValue(forKey: .cursor)

            gate.open()
            await refresh.value

            XCTAssertNil(
                viewModel.providerQuotas[.cursor],
                "Removing the provider during the fetch must survive the refresh write"
            )
        }
    }

    /// The IDE refresh holds the provider's refresh-coordination slot for the *whole*
    /// fetch/write, so a scoped refresh cannot start midway through it and be clobbered.
    /// `isRefreshBlocked(for:)` reads the same set `beginScopedRefresh` inserts into, so
    /// this is also what disables the per-account refresh button in `QuotaScreen` and
    /// `StatusBarMenuBuilder` while the fetch is in flight.
    @MainActor
    func testScopedRefreshIsBlockedWhileImportedIDEFetchIsSuspended() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let account = "user@example.com"
            let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
            let fresh = quota(60, lastUpdated: Date(timeIntervalSince1970: 2_000))
            viewModel.providerQuotas = [.cursor: [account: stale]]

            let accountID = QuotaAccountID(provider: .cursor, accountKey: account)
            XCTAssertFalse(viewModel.isRefreshBlocked(for: accountID))

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            var fetchCount = 0
            viewModel.ideQuotaFetchHookForTesting = { _ in
                fetchCount += 1
                suspendedInFetch.fulfill()
                await gate.wait()
                return [account: fresh]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)

            XCTAssertTrue(
                viewModel.isRefreshBlocked(for: accountID),
                "The coordination slot must be held across the fetch, not only before it"
            )
            XCTAssertTrue(viewModel.isRefreshing(provider: .cursor))

            // A scoped refresh requested now is rejected by the slot instead of racing the
            // in-flight write: it performs no fetch and leaves the quota untouched.
            await viewModel.refreshQuota(for: .cursor)
            XCTAssertEqual(
                viewModel.providerQuotas[.cursor]?[account]?.lastUpdated,
                stale.lastUpdated,
                "A scoped refresh must not run while the global IDE refresh holds the slot"
            )

            // A second global refresh is rejected by the same slot and issues no fetch.
            await viewModel.refreshImportedIDEQuotas()
            XCTAssertEqual(fetchCount, 1, "The slot must serialise overlapping IDE refreshes")

            gate.open()
            await refresh.value

            XCTAssertFalse(viewModel.isRefreshBlocked(for: accountID), "The slot must be released")
            XCTAssertEqual(viewModel.providerQuotas[.cursor]?[account]?.models.first?.percentage, 60)
        }
    }

    /// With nothing imported the refresh must not acquire the slot, fetch, or import —
    /// Cursor/Trae stay explicit-scan only (issue #29).
    @MainActor
    func testGlobalRefreshDoesNotFetchWhenNothingIsImported() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            viewModel.providerQuotas = [:]

            var fetchCount = 0
            viewModel.ideQuotaFetchHookForTesting = { _ in
                fetchCount += 1
                return ["user@example.com": self.quota(50, lastUpdated: Date())]
            }

            await viewModel.refreshImportedIDEQuotas()

            XCTAssertEqual(fetchCount, 0, "A refresh must not read the IDE databases without an explicit scan")
            XCTAssertTrue(viewModel.providerQuotas.isEmpty)
        }
    }
}
