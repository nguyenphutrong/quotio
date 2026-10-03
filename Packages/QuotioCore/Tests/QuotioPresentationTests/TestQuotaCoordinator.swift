import QuotioApplication
import QuotioDomain

actor TestQuotaCoordinator: QuotaCoordinating {
    private(set) var snapshot: QuotaSnapshot
    private let refreshedSnapshot: QuotaSnapshot?
    private let refreshGate: TestAsyncGate?
    private var continuation: AsyncStream<QuotaSnapshot>.Continuation?
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshStarted = false

    init(
        snapshot: QuotaSnapshot = QuotaSnapshot(),
        refreshedSnapshot: QuotaSnapshot? = nil,
        refreshGate: TestAsyncGate? = nil
    ) {
        self.snapshot = snapshot
        self.refreshedSnapshot = refreshedSnapshot
        self.refreshGate = refreshGate
    }

    func states() -> AsyncStream<QuotaSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: QuotaSnapshot.self)
        self.continuation = continuation
        continuation.yield(snapshot)
        return stream
    }

    func bootstrap(mode: QuotaOperatingMode) -> QuotaSnapshot { snapshot }

    func refresh(_ request: QuotaFetchRequest) async -> QuotaSnapshot {
        refreshStarted = true
        refreshWaiters.forEach { $0.resume() }
        refreshWaiters.removeAll()
        if let refreshGate { await refreshGate.wait() }
        if let refreshedSnapshot { snapshot = refreshedSnapshot }
        continuation?.yield(snapshot)
        return snapshot
    }

    func refreshAll(
        mode: QuotaOperatingMode,
        providers: Set<QuotaProvider>?,
        force: Bool
    ) async -> QuotaSnapshot {
        snapshot
    }

    func replaceQuotas(
        _ quotas: [String: ProviderQuota],
        for provider: QuotaProvider,
        mode: QuotaOperatingMode
    ) {
        snapshot.quotas[provider] = quotas
        continuation?.yield(snapshot)
    }

    func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) {
        snapshot.quotas[account.provider]?[account.accountKey] = nil
        if snapshot.quotas[account.provider]?.isEmpty == true {
            snapshot.quotas[account.provider] = nil
        }
        continuation?.yield(snapshot)
    }

    func cancel(provider: QuotaProvider) {}
    func cancelForTermination() {}

    func waitUntilRefreshStarts() async {
        if refreshStarted { return }
        await withCheckedContinuation { refreshWaiters.append($0) }
    }
}

actor TestAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
