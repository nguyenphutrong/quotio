import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class QuotaScreenModel {
    public private(set) var state: QuotaSnapshot {
        didSet {
            guard oldValue != state else { return }
            didChangeHandler?(state)
        }
    }

    @ObservationIgnored private let coordinator: QuotaRefreshCoordinator
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var didChangeHandler: (@MainActor (QuotaSnapshot) -> Void)?

    public init(
        coordinator: QuotaRefreshCoordinator,
        initialState: QuotaSnapshot = QuotaSnapshot()
    ) {
        self.coordinator = coordinator
        state = initialState
        observe()
    }

    deinit {
        observationTask?.cancel()
    }

    public var providerQuotas: [QuotaProvider: [String: ProviderQuota]] { state.quotas }
    public var subscriptionInfos: [QuotaProvider: [String: QuotaSubscriptionInfo]] { state.subscriptions }
    public var refreshingProviders: Set<QuotaProvider> { state.refreshingProviders }
    public var isLoadingQuotas: Bool { !state.refreshingProviders.isEmpty }
    public var lastRefreshTime: Date? { state.lastUpdated }

    public func isRefreshing(provider: QuotaProvider) -> Bool {
        state.refreshingProviders.contains(provider)
    }

    public func isRefreshing(account: QuotaAccountID) -> Bool {
        state.refreshingProviders.contains(account.provider)
    }

    public func isRefreshBlocked(for account: QuotaAccountID) -> Bool {
        state.refreshingProviders.contains(account.provider)
    }

    public func supportsScopedRefresh(for provider: QuotaProvider) -> Bool {
        provider.supportsQuotaOnlyMode
    }

    public func setDidChangeHandler(
        _ handler: (@MainActor (QuotaSnapshot) -> Void)?
    ) {
        didChangeHandler = handler
    }

    public func bootstrap(mode: QuotaOperatingMode) async {
        state = await coordinator.bootstrap(mode: mode)
    }

    public func refresh(
        provider: QuotaProvider,
        scope: QuotaFetchScope = .provider,
        mode: QuotaOperatingMode,
        force: Bool = false
    ) async {
        state = await coordinator.refresh(QuotaFetchRequest(
            provider: provider,
            scope: scope,
            mode: mode,
            force: force
        ))
    }

    public func refreshAll(
        mode: QuotaOperatingMode,
        providers: Set<QuotaProvider>? = nil,
        force: Bool = false
    ) async {
        state = await coordinator.refreshAll(
            mode: mode,
            providers: providers,
            force: force
        )
    }

    public func replaceQuotas(
        _ quotas: [String: ProviderQuota],
        for provider: QuotaProvider,
        mode: QuotaOperatingMode
    ) async {
        await coordinator.replaceQuotas(quotas, for: provider, mode: mode)
        state = await coordinator.snapshot
    }

    public func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) async {
        await coordinator.removeQuota(for: account, mode: mode)
        state = await coordinator.snapshot
    }

    public func cancel(provider: QuotaProvider) async {
        await coordinator.cancel(provider: provider)
        state = await coordinator.snapshot
    }

    public func shutdown() async {
        observationTask?.cancel()
        observationTask = nil
        await coordinator.cancelForTermination()
        state.refreshingProviders.removeAll()
    }

    private func observe() {
        let coordinator = coordinator
        observationTask = Task { [weak self] in
            let states = await coordinator.states()
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                self.state = state
            }
        }
    }
}
