import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class QuotaRefreshCoordinatorTests: XCTestCase {
    func testRefreshRoutesThroughRegisteredProviderAndPersistsResult() async {
        let quota = Self.quota(75)
        let fetcher = StubQuotaFetcher(provider: .codex, outputs: [
            QuotaProviderOutput(quotas: ["account": quota]),
        ])
        let store = MemoryQuotaStore()
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(
            provider: .codex,
            mode: .monitor
        ))

        XCTAssertEqual(snapshot.quotas[.codex], ["account": quota])
        let saved = await store.saved
        XCTAssertEqual(saved.last?.snapshot, snapshot.persisted)
        XCTAssertEqual(saved.last?.mode, .monitor)
    }

    func testRefreshCanonicalizesPersistedAccountAliasesBeforeMergingFreshQuota() async {
        let stale = Self.quota(20)
        let fresh = Self.quota(90)
        let fetcher = StubQuotaFetcher(provider: .codex, outputs: [
            QuotaProviderOutput(
                quotas: ["same@example.com": fresh],
                credentialAccountKeys: ["same@example.com"],
                accountAliases: ["same@example.com-pro": "same@example.com"]
            ),
        ])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .codex: ["same@example.com": stale, "same@example.com-pro": stale],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(provider: .codex, mode: .monitor))

        XCTAssertEqual(snapshot.quotas[.codex], ["same@example.com": fresh])
        let saved = await store.saved
        XCTAssertEqual(saved.last?.snapshot.quotas[.codex], ["same@example.com": fresh])
    }

    func testConcurrentRefreshesForProviderShareOneFetch() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .claude,
            outputs: [QuotaProviderOutput(quotas: ["account": Self.quota(50)])],
            gate: gate
        )
        let coordinator = makeCoordinator(fetchers: [fetcher])

        async let first = coordinator.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        await fetcher.waitUntilCalled()
        let second = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        }
        await Task.yield()
        await gate.open()
        _ = await (first, second.value)

        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testConcurrentRefreshesRejectDifferentScopeAndModeWhileProviderIsActive() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .claude,
            outputs: [QuotaProviderOutput(quotas: ["account": Self.quota(50)])],
            gate: gate
        )
        let coordinator = makeCoordinator(fetchers: [fetcher])

        let active = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        let scopeCompletion = CompletionFlag()
        let modeCompletion = CompletionFlag()
        let differentScope = Task {
            _ = await coordinator.refresh(QuotaFetchRequest(
                provider: .claude,
                scope: .account("account"),
                mode: .monitor
            ))
            await scopeCompletion.finish()
        }
        let differentMode = Task {
            _ = await coordinator.refresh(QuotaFetchRequest(provider: .claude, mode: .localProxy))
            await modeCompletion.finish()
        }
        try? await Task.sleep(for: .milliseconds(20))

        let didRejectScope = await scopeCompletion.isFinished
        let didRejectMode = await modeCompletion.isFinished
        XCTAssertTrue(didRejectScope)
        XCTAssertTrue(didRejectMode)

        await gate.open()
        _ = await (active.value, differentScope.value, differentMode.value)
        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testFailureKeepsPreviousQuotaAndAppliesRetryDelay() async {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let fetcher = StubQuotaFetcher(provider: .codex, outputs: [nil, QuotaProviderOutput(quotas: [
            "account": Self.quota(90),
        ])])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .codex: ["account": Self.quota(20)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store, clock: clock)
        _ = await coordinator.bootstrap(mode: .monitor)

        let failed = await coordinator.refresh(QuotaFetchRequest(provider: .codex, mode: .monitor))
        let blocked = await coordinator.refresh(QuotaFetchRequest(provider: .codex, mode: .monitor))

        XCTAssertEqual(failed.quotas[.codex]?["account"], Self.quota(20))
        XCTAssertEqual(failed.issues[.codex]?.kind, .failed)
        XCTAssertEqual(blocked, failed)
        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testMissingCredentialClearsStaleProviderQuota() async {
        let fetcher = StubQuotaFetcher(provider: .amp, outputs: [
            QuotaProviderOutput(quotas: [:], credentialAvailability: .missing),
        ])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .amp: ["old": Self.quota(20)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(provider: .amp, mode: .monitor))

        XCTAssertNil(snapshot.quotas[.amp])
        XCTAssertNil(snapshot.issues[.amp])
    }

    func testCredentialIdentityReconciliationIsCaseInsensitive() async {
        let fetcher = StubQuotaFetcher(provider: .kiro, outputs: [
            QuotaProviderOutput(
                quotas: [:],
                credentialAvailability: .present,
                credentialAccountKeys: ["person@example.com"]
            ),
        ])
        let previous = Self.quota(20)
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .kiro: ["Person@example.com": previous],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(provider: .kiro, mode: .monitor))

        XCTAssertEqual(snapshot.quotas[.kiro]?["Person@example.com"], previous)
        XCTAssertEqual(snapshot.issues[.kiro]?.kind, .failed)
    }

    func testAccountFailureDoesNotBlockAnotherAccountRefresh() async {
        let fetcher = StubQuotaFetcher(provider: .codex, outputs: [nil, QuotaProviderOutput(quotas: [
            "second": Self.quota(90),
        ])])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .codex: ["first": Self.quota(20), "second": Self.quota(30)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let failed = await coordinator.refresh(QuotaFetchRequest(
            provider: .codex,
            scope: .account("first"),
            mode: .monitor
        ))
        let refreshed = await coordinator.refresh(QuotaFetchRequest(
            provider: .codex,
            scope: .account("second"),
            mode: .monitor
        ))

        let first = QuotaAccountID(provider: .codex, accountKey: "first")
        XCTAssertEqual(failed.accountIssues[first]?.kind, .failed)
        XCTAssertEqual(refreshed.quotas[.codex]?["second"], Self.quota(90))
        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testPartialRefreshMergesPreviousAccountsAndReportsIssue() async {
        let fetcher = StubQuotaFetcher(provider: .copilot, outputs: [
            QuotaProviderOutput(quotas: ["fresh": Self.quota(80)]),
        ])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .copilot: ["fresh": Self.quota(10), "missing": Self.quota(30)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(provider: .copilot, mode: .monitor))

        XCTAssertEqual(snapshot.quotas[.copilot]?["fresh"], Self.quota(80))
        XCTAssertEqual(snapshot.quotas[.copilot]?["missing"], Self.quota(30))
        XCTAssertEqual(snapshot.issues[.copilot]?.kind, .partial)
    }

    func testProviderRefreshDropsAccountsWhoseCredentialsNoLongerExist() async {
        let fetcher = StubQuotaFetcher(provider: .grok, outputs: [
            QuotaProviderOutput(
                quotas: ["fresh": Self.quota(80), "new": Self.quota(90)],
                credentialAvailability: .present,
                credentialAccountKeys: ["fresh", "failed", "new"]
            ),
        ])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .grok: [
                "fresh": Self.quota(10),
                "failed": Self.quota(20),
                "removed": Self.quota(30),
            ],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(provider: .grok, mode: .monitor))

        XCTAssertEqual(snapshot.quotas[.grok]?["fresh"], Self.quota(80))
        XCTAssertEqual(snapshot.quotas[.grok]?["failed"], Self.quota(20))
        XCTAssertEqual(snapshot.quotas[.grok]?["new"], Self.quota(90))
        XCTAssertNil(snapshot.quotas[.grok]?["removed"])
        XCTAssertEqual(snapshot.issues[.grok]?.kind, .partial)
    }

    func testImportedRefreshCannotResurrectRemovedAccount() async {
        let fetcher = StubQuotaFetcher(provider: .cursor, outputs: [
            QuotaProviderOutput(quotas: [
                "kept": Self.quota(80),
                "deleted": Self.quota(90),
            ]),
        ])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .cursor: ["kept": Self.quota(10)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(
            provider: .cursor,
            scope: .importedAccounts(["kept"]),
            mode: .monitor
        ))

        XCTAssertEqual(snapshot.quotas[.cursor], ["kept": Self.quota(80)])
    }

    func testImportedRefreshCannotResurrectAccountRemovedWhileFetchIsSuspended() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .cursor,
            outputs: [QuotaProviderOutput(quotas: [
                "kept": Self.quota(80),
                "deleted": Self.quota(90),
            ])],
            gate: gate
        )
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .cursor: ["kept": Self.quota(10), "deleted": Self.quota(20)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let refresh = Task {
            await coordinator.refresh(QuotaFetchRequest(
                provider: .cursor,
                scope: .importedAccounts(["kept", "deleted"]),
                mode: .monitor
            ))
        }
        await fetcher.waitUntilCalled()
        await coordinator.removeQuota(
            for: QuotaAccountID(provider: .cursor, accountKey: "deleted"),
            mode: .monitor
        )
        await gate.open()
        _ = await refresh.value

        let snapshot = await coordinator.snapshot
        XCTAssertNil(snapshot.quotas[.cursor]?["deleted"])
        XCTAssertEqual(snapshot.quotas[.cursor]?["kept"], Self.quota(80))
    }

    func testEmptyImportedScopeDoesNotFetchOrImportAccounts() async {
        let fetcher = StubQuotaFetcher(provider: .trae, outputs: [
            QuotaProviderOutput(quotas: ["new": Self.quota(80)]),
        ])
        let coordinator = makeCoordinator(fetchers: [fetcher])

        let snapshot = await coordinator.refresh(QuotaFetchRequest(
            provider: .trae,
            scope: .importedAccounts([]),
            mode: .monitor
        ))

        XCTAssertTrue(snapshot.quotas.isEmpty)
        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testProviderRefreshCanonicalizesAliasesBeforeMerging() async {
        let fresh = Self.quota(80)
        let fetcher = StubQuotaFetcher(provider: .copilot, outputs: [
            QuotaProviderOutput(
                quotas: ["user": fresh],
                credentialAvailability: .present,
                accountAliases: ["github-copilot-user.json": "user"]
            ),
        ])
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .copilot: ["github-copilot-user.json": Self.quota(10)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let snapshot = await coordinator.refresh(QuotaFetchRequest(
            provider: .copilot,
            mode: .monitor
        ))

        XCTAssertEqual(snapshot.quotas[.copilot], ["user": fresh])
    }

    func testRemovingQuotaInvalidatesInFlightProviderRefresh() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .cursor,
            outputs: [QuotaProviderOutput(quotas: ["deleted": Self.quota(90)])],
            gate: gate
        )
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .cursor: [
                "deleted": Self.quota(10),
                "DELETED": Self.quota(20),
            ],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let refresh = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .cursor, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        await coordinator.removeQuota(
            for: QuotaAccountID(provider: .cursor, accountKey: "deleted"),
            mode: .monitor
        )
        await gate.open()
        _ = await refresh.value

        let snapshot = await coordinator.snapshot
        XCTAssertNil(snapshot.quotas[.cursor]?["deleted"])
        XCTAssertFalse(snapshot.refreshingProviders.contains(.cursor))
    }

    func testRemovingAliasInvalidatesCanonicalResultFromInFlightRefresh() async {
        let gate = AsyncGate()
        let alias = "github-copilot-octocat.json"
        let fetcher = StubQuotaFetcher(
            provider: .copilot,
            outputs: [QuotaProviderOutput(
                quotas: ["octocat": Self.quota(90)],
                credentialAvailability: .present,
                credentialAccountKeys: ["octocat"],
                accountAliases: [alias: "octocat"]
            )],
            gate: gate
        )
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .copilot: [alias: Self.quota(10)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let refresh = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .copilot, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        await coordinator.removeQuota(
            for: QuotaAccountID(provider: .copilot, accountKey: alias),
            mode: .monitor
        )
        await gate.open()
        _ = await refresh.value

        let snapshot = await coordinator.snapshot
        XCTAssertNil(snapshot.quotas[.copilot]?["octocat"])
    }

    func testCancelledRefreshCannotPublishLateResult() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .trae,
            outputs: [QuotaProviderOutput(quotas: ["account": Self.quota(90)])],
            gate: gate
        )
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .trae: ["account": Self.quota(10)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let refresh = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .trae, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        await coordinator.cancel(provider: .trae)
        await gate.open()
        _ = await refresh.value

        let snapshot = await coordinator.snapshot
        XCTAssertEqual(snapshot.quotas[.trae]?["account"], Self.quota(10))
        XCTAssertFalse(snapshot.refreshingProviders.contains(.trae))
    }

    func testCallerCancellationCannotPublishOrPersistLateResult() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .trae,
            outputs: [QuotaProviderOutput(quotas: ["account": Self.quota(90)])],
            gate: gate
        )
        let store = MemoryQuotaStore(initial: QuotaSnapshot(quotas: [
            .trae: ["account": Self.quota(10)],
        ]))
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let refresh = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .trae, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        refresh.cancel()
        await gate.open()
        _ = await refresh.value

        let snapshot = await coordinator.snapshot
        let saves = await store.saved
        XCTAssertEqual(snapshot.quotas[.trae]?["account"], Self.quota(10))
        XCTAssertFalse(snapshot.refreshingProviders.contains(.trae))
        XCTAssertTrue(saves.isEmpty)
    }

    func testCancelledSharedWaiterDoesNotPreventValidWaiterFromApplyingResult() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .claude,
            outputs: [QuotaProviderOutput(quotas: ["account": Self.quota(90)])],
            gate: gate
        )
        let coordinator = makeCoordinator(fetchers: [fetcher])

        let cancelled = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        let valid = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        }
        await Task.yield()
        cancelled.cancel()
        await gate.open()
        _ = await (cancelled.value, valid.value)

        let snapshot = await coordinator.snapshot
        let callCount = await fetcher.callCount
        XCTAssertEqual(snapshot.quotas[.claude]?["account"], Self.quota(90))
        XCTAssertEqual(callCount, 1)
    }

    func testBootstrapCancelsOldModeRefreshAndRejectsItsLateResult() async {
        let gate = AsyncGate()
        let fetcher = StubQuotaFetcher(
            provider: .codex,
            outputs: [QuotaProviderOutput(quotas: ["account": Self.quota(90)])],
            gate: gate
        )
        let initial = QuotaSnapshot(quotas: [.codex: ["account": Self.quota(10)]])
        let store = MemoryQuotaStore(initial: initial)
        let coordinator = makeCoordinator(fetchers: [fetcher], store: store)
        _ = await coordinator.bootstrap(mode: .monitor)

        let refresh = Task {
            await coordinator.refresh(QuotaFetchRequest(provider: .codex, mode: .monitor))
        }
        await fetcher.waitUntilCalled()
        let bootstrapped = await coordinator.bootstrap(mode: .localProxy)
        await gate.open()
        _ = await refresh.value

        let snapshot = await coordinator.snapshot
        let saves = await store.saved
        XCTAssertEqual(bootstrapped, initial)
        XCTAssertEqual(snapshot, initial)
        XCTAssertTrue(saves.isEmpty)
    }

    private func makeCoordinator(
        fetchers: [any QuotaFetching],
        store: MemoryQuotaStore = MemoryQuotaStore(),
        clock: TestClock = TestClock(now: Date(timeIntervalSince1970: 1_000))
    ) -> QuotaRefreshCoordinator {
        QuotaRefreshCoordinator(
            registry: QuotaProviderRegistry(fetchers),
            snapshots: store,
            clock: clock
        )
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(
            models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: percentage)
        )
    }
}

private actor StubQuotaFetcher: QuotaFetching {
    nonisolated let provider: QuotaProvider
    private var outputs: [QuotaProviderOutput?]
    private let gate: AsyncGate?
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    init(provider: QuotaProvider, outputs: [QuotaProviderOutput?], gate: AsyncGate? = nil) {
        self.provider = provider
        self.outputs = outputs
        self.gate = gate
    }

    func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
        callCount += 1
        for continuation in callContinuations {
            continuation.resume()
        }
        callContinuations.removeAll()
        if let gate { await gate.wait() }
        guard !outputs.isEmpty, let output = outputs.removeFirst() else {
            throw TestError.failed
        }
        return output
    }

    func waitUntilCalled() async {
        if callCount > 0 { return }
        await withCheckedContinuation { callContinuations.append($0) }
    }
}

private actor MemoryQuotaStore: QuotaSnapshotStoring {
    struct Save: Sendable {
        let snapshot: QuotaSnapshot
        let mode: QuotaOperatingMode
    }

    private let initial: QuotaSnapshot
    private(set) var saved: [Save] = []

    init(initial: QuotaSnapshot = QuotaSnapshot()) {
        self.initial = initial
    }

    func load(for mode: QuotaOperatingMode) -> QuotaSnapshot { initial }

    func save(_ snapshot: QuotaSnapshot, for mode: QuotaOperatingMode) {
        saved.append(Save(snapshot: snapshot, mode: mode))
    }
}

private struct TestClock: DateProviding {
    let nowValue: Date

    init(now: Date) {
        nowValue = now
    }

    func now() -> Date { nowValue }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }
}

private actor CompletionFlag {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private enum TestError: Error {
    case failed
}
