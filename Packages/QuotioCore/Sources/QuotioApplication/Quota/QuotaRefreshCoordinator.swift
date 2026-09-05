import Foundation
import QuotioDomain

public enum QuotaRefreshIssueKind: Equatable, Sendable {
    case failed
    case partial
}

public struct QuotaRefreshIssue: Equatable, Sendable {
    public let kind: QuotaRefreshIssueKind
    public let occurredAt: Date

    public init(kind: QuotaRefreshIssueKind, occurredAt: Date) {
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public struct QuotaSnapshot: Equatable, Sendable {
    public var quotas: [QuotaProvider: [String: ProviderQuota]]
    public var accountAliases: [QuotaProvider: [String: String]]
    public var subscriptions: [QuotaProvider: [String: QuotaSubscriptionInfo]]
    public var issues: [QuotaProvider: QuotaRefreshIssue]
    public var accountIssues: [QuotaAccountID: QuotaRefreshIssue]
    public var refreshingProviders: Set<QuotaProvider>
    public var lastUpdated: Date?

    public init(
        quotas: [QuotaProvider: [String: ProviderQuota]] = [:],
        accountAliases: [QuotaProvider: [String: String]] = [:],
        subscriptions: [QuotaProvider: [String: QuotaSubscriptionInfo]] = [:],
        issues: [QuotaProvider: QuotaRefreshIssue] = [:],
        accountIssues: [QuotaAccountID: QuotaRefreshIssue] = [:],
        refreshingProviders: Set<QuotaProvider> = [],
        lastUpdated: Date? = nil
    ) {
        self.quotas = quotas
        self.accountAliases = accountAliases
        self.subscriptions = subscriptions
        self.issues = issues
        self.accountIssues = accountIssues
        self.refreshingProviders = refreshingProviders
        self.lastUpdated = lastUpdated
    }

    public var persisted: QuotaSnapshot {
        var copy = self
        copy.refreshingProviders = []
        return copy
    }
}

public actor QuotaRefreshCoordinator: LifecycleCancelling {
    private enum RetryScope: Hashable {
        case provider(QuotaProvider)
        case account(QuotaAccountID)
    }

    private struct InFlight {
        let id: UUID
        let request: QuotaFetchRequest
        let removalGeneration: UInt64
        let task: Task<QuotaProviderOutput?, Never>
        var waiters: Set<UUID>
    }

    private let registry: QuotaProviderRegistry
    private let snapshots: any QuotaSnapshotStoring
    private let clock: any DateProviding
    private let retryDelay: TimeInterval
    private var inFlight: [QuotaProvider: InFlight] = [:]
    private var retryAfter: [RetryScope: Date] = [:]
    private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]
    private var activeMode: QuotaOperatingMode?
    private var bootstrapGeneration: UInt64?
    private var generation: UInt64 = 0
    private var removalGeneration: UInt64 = 0
    private var accountRemovalGenerations: [QuotaAccountID: UInt64] = [:]
    private(set) public var snapshot = QuotaSnapshot()

    public init(
        registry: QuotaProviderRegistry,
        snapshots: any QuotaSnapshotStoring,
        clock: any DateProviding,
        retryDelay: TimeInterval = 60
    ) {
        self.registry = registry
        self.snapshots = snapshots
        self.clock = clock
        self.retryDelay = retryDelay
    }

    public func states() -> AsyncStream<QuotaSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    @discardableResult
    public func bootstrap(mode: QuotaOperatingMode) async -> QuotaSnapshot {
        generation &+= 1
        let requestedGeneration = generation
        bootstrapGeneration = requestedGeneration
        activeMode = mode
        cancelAllInFlight()
        retryAfter.removeAll()
        publish()

        let loaded = await snapshots.load(for: mode).persisted
        guard bootstrapGeneration == requestedGeneration else { return snapshot }
        bootstrapGeneration = nil
        snapshot = loaded
        publish()
        return snapshot
    }

    @discardableResult
    public func refresh(_ request: QuotaFetchRequest) async -> QuotaSnapshot {
        if case .importedAccounts(let accountKeys) = request.scope, accountKeys.isEmpty {
            return snapshot
        }
        guard bootstrapGeneration == nil else { return snapshot }
        if let activeMode, activeMode != request.mode { return snapshot }
        activeMode = request.mode
        let retryScope = retryScope(for: request)
        if !request.force,
           let retryDate = retryAfter[retryScope],
           retryDate > clock.now() {
            return snapshot
        }
        guard let fetcher = registry.fetcher(for: request.provider) else { return snapshot }

        let waiterID = UUID()
        let operation: InFlight
        if var existing = inFlight[request.provider] {
            guard existing.request == request else { return snapshot }
            existing.waiters.insert(waiterID)
            inFlight[request.provider] = existing
            operation = existing
        } else {
            let id = UUID()
            let task = Task<QuotaProviderOutput?, Never> {
                do {
                    return try await fetcher.fetch(request)
                } catch {
                    return nil
                }
            }
            operation = InFlight(
                id: id,
                request: request,
                removalGeneration: removalGeneration,
                task: task,
                waiters: [waiterID]
            )
            inFlight[request.provider] = operation
            snapshot.refreshingProviders.insert(request.provider)
            publish()
        }

        let output = await operation.task.value
        guard !Task.isCancelled else {
            removeWaiter(waiterID, from: operation)
            return snapshot
        }
        guard inFlight[request.provider]?.id == operation.id,
              activeMode == request.mode,
              bootstrapGeneration == nil else { return snapshot }
        inFlight.removeValue(forKey: request.provider)
        snapshot.refreshingProviders.remove(request.provider)

        guard !operation.task.isCancelled else {
            publish()
            return snapshot
        }

        apply(
            output,
            request: request,
            operationRemovalGeneration: operation.removalGeneration
        )
        await snapshots.save(snapshot.persisted, for: request.mode)
        publish()
        return snapshot
    }

    @discardableResult
    public func refreshAll(
        mode: QuotaOperatingMode,
        providers: Set<QuotaProvider>? = nil,
        force: Bool = false
    ) async -> QuotaSnapshot {
        let selected = providers ?? registry.providers
        await withTaskGroup(of: Void.self) { group in
            for provider in selected {
                group.addTask { [self] in
                    await refresh(QuotaFetchRequest(
                        provider: provider,
                        mode: mode,
                        force: force
                    ))
                }
            }
        }
        return snapshot
    }

    public func replaceQuotas(
        _ quotas: [String: ProviderQuota],
        for provider: QuotaProvider,
        mode: QuotaOperatingMode
    ) async {
        if quotas.isEmpty {
            snapshot.quotas.removeValue(forKey: provider)
        } else {
            snapshot.quotas[provider] = quotas
        }
        snapshot.lastUpdated = clock.now()
        await snapshots.save(snapshot.persisted, for: mode)
        publish()
    }

    public func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) async {
        removalGeneration &+= 1
        accountRemovalGenerations[normalized(account)] = removalGeneration
        snapshot.quotas[account.provider] = snapshot.quotas[account.provider]?.filter {
            $0.key.caseInsensitiveCompare(account.accountKey) != .orderedSame
        }
        if snapshot.quotas[account.provider]?.isEmpty == true {
            snapshot.quotas.removeValue(forKey: account.provider)
        }
        snapshot.subscriptions[account.provider] = snapshot.subscriptions[account.provider]?.filter {
            $0.key.caseInsensitiveCompare(account.accountKey) != .orderedSame
        }
        if snapshot.subscriptions[account.provider]?.isEmpty == true {
            snapshot.subscriptions.removeValue(forKey: account.provider)
        }
        snapshot.accountIssues = snapshot.accountIssues.filter {
            $0.key.provider != account.provider
                || $0.key.accountKey.caseInsensitiveCompare(account.accountKey) != .orderedSame
        }
        retryAfter = retryAfter.filter { scope, _ in
            guard case .account(let retryAccount) = scope else { return true }
            return retryAccount.provider != account.provider
                || retryAccount.accountKey.caseInsensitiveCompare(account.accountKey) != .orderedSame
        }
        snapshot.lastUpdated = clock.now()
        await snapshots.save(snapshot.persisted, for: mode)
        publish()
    }

    public func cancel(provider: QuotaProvider) {
        inFlight.removeValue(forKey: provider)?.task.cancel()
        snapshot.refreshingProviders.remove(provider)
        publish()
    }

    public func cancelForTermination() {
        cancelAllInFlight()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func apply(
        _ fetchedOutput: QuotaProviderOutput?,
        request: QuotaFetchRequest,
        operationRemovalGeneration: UInt64
    ) {
        let provider = request.provider
        let now = clock.now()

        guard var output = fetchedOutput else {
            let previous = snapshot.quotas[provider] ?? [:]
            if hasPreviousQuota(for: request, in: previous) {
                recordFailure(for: request, at: now)
            }
            snapshot.lastUpdated = now
            return
        }

        output.quotas = output.quotas.filter { accountKey, _ in
            !wasRemoved(
                provider: provider,
                accountKey: accountKey,
                aliases: output.accountAliases,
                after: operationRemovalGeneration
            )
        }
        output.subscriptions = output.subscriptions.filter { accountKey, _ in
            !wasRemoved(
                provider: provider,
                accountKey: accountKey,
                aliases: output.accountAliases,
                after: operationRemovalGeneration
            )
        }
        switch request.scope {
        case .provider:
            snapshot.accountAliases[provider] = output.accountAliases
        case .account, .importedAccounts:
            snapshot.accountAliases[provider, default: [:]].merge(output.accountAliases) { _, fresh in fresh }
        }
        let previous = QuotaPolicy.canonicalizedAccounts(
            snapshot.quotas[provider] ?? [:],
            aliases: output.accountAliases
        )
        let credentialAccountKeys = output.credentialAccountKeys.map { keys in
            Set(keys.compactMap { key in
                let canonicalKey = output.accountAliases[key] ?? key
                return wasRemoved(
                    provider: provider,
                    accountKey: canonicalKey,
                    aliases: output.accountAliases,
                    after: operationRemovalGeneration
                ) ? nil : canonicalKey
            })
        }

        let refreshed: [String: ProviderQuota]
        switch request.scope {
        case .provider:
            refreshed = mergedProviderResult(
                output.quotas,
                previous: previous,
                availability: output.credentialAvailability,
                credentialAccountKeys: credentialAccountKeys,
                provider: provider,
                now: now
            )
            if let credentialAccountKeys {
                let normalizedCredentialKeys = Set(credentialAccountKeys.map { $0.lowercased() })
                let subscriptions = snapshot.subscriptions[provider]?.filter {
                    normalizedCredentialKeys.contains($0.key.lowercased())
                } ?? [:]
                if subscriptions.isEmpty {
                    snapshot.subscriptions.removeValue(forKey: provider)
                } else {
                    snapshot.subscriptions[provider] = subscriptions
                }
            }
        case .account(let accountKey):
            let account = QuotaAccountID(provider: provider, accountKey: accountKey)
            let canonicalKey = output.accountAliases[accountKey] ?? accountKey
            if wasRemoved(
                provider: provider,
                accountKey: canonicalKey,
                aliases: output.accountAliases,
                after: operationRemovalGeneration
            ) {
                refreshed = previous
            } else if let quota = output.quotas[canonicalKey] {
                var merged = previous
                merged[canonicalKey] = quota
                refreshed = merged
                clearIssue(for: account)
            } else {
                refreshed = previous
                recordFailure(for: request, at: now)
            }
        case .importedAccounts:
            refreshed = QuotaPolicy.mergeImportedIDEQuotas(fetched: output.quotas, into: previous)
            clearIssue(for: provider)
        }

        if refreshed.isEmpty {
            snapshot.quotas.removeValue(forKey: provider)
        } else {
            snapshot.quotas[provider] = refreshed
        }
        if !output.subscriptions.isEmpty {
            snapshot.subscriptions[provider, default: [:]].merge(output.subscriptions) { _, fresh in fresh }
        }
        snapshot.lastUpdated = now
    }

    private func mergedProviderResult(
        _ fresh: [String: ProviderQuota],
        previous: [String: ProviderQuota],
        availability: QuotaCredentialAvailability,
        credentialAccountKeys: Set<String>?,
        provider: QuotaProvider,
        now: Date
    ) -> [String: ProviderQuota] {
        let previous = credentialAccountKeys.map { keys in
            let normalizedKeys = Set(keys.map { $0.lowercased() })
            return previous.filter { normalizedKeys.contains($0.key.lowercased()) }
        } ?? previous
        if fresh.isEmpty, availability == .missing {
            clearIssue(for: provider)
            return [:]
        }
        if fresh.isEmpty, !previous.isEmpty {
            snapshot.issues[provider] = QuotaRefreshIssue(kind: .failed, occurredAt: now)
            retryAfter[.provider(provider)] = now.addingTimeInterval(retryDelay)
            return previous
        }
        guard !fresh.isEmpty else {
            clearIssue(for: provider)
            return [:]
        }

        var merged = previous
        merged.merge(fresh) { _, fresh in fresh }
        let missingCredentialQuota = credentialAccountKeys.map { keys in
            let normalizedKeys = Set(keys.map { $0.lowercased() })
            let normalizedFreshKeys = Set(fresh.keys.map { $0.lowercased() })
            return !normalizedKeys.isSubset(of: normalizedFreshKeys)
        } ?? (fresh.count < previous.count)
        if missingCredentialQuota {
            snapshot.issues[provider] = QuotaRefreshIssue(kind: .partial, occurredAt: now)
            retryAfter[.provider(provider)] = now.addingTimeInterval(retryDelay)
        } else {
            clearIssue(for: provider)
        }
        return merged
    }

    private func clearIssue(for provider: QuotaProvider) {
        snapshot.issues.removeValue(forKey: provider)
        snapshot.accountIssues = snapshot.accountIssues.filter { $0.key.provider != provider }
        retryAfter = retryAfter.filter { scope, _ in
            switch scope {
            case .provider(let issueProvider): issueProvider != provider
            case .account(let account): account.provider != provider
            }
        }
    }

    private func clearIssue(for account: QuotaAccountID) {
        snapshot.accountIssues.removeValue(forKey: account)
        retryAfter.removeValue(forKey: .account(account))
    }

    private func retryScope(for request: QuotaFetchRequest) -> RetryScope {
        switch request.scope {
        case .account(let accountKey):
            .account(QuotaAccountID(provider: request.provider, accountKey: accountKey))
        case .provider, .importedAccounts:
            .provider(request.provider)
        }
    }

    private func hasPreviousQuota(
        for request: QuotaFetchRequest,
        in previous: [String: ProviderQuota]
    ) -> Bool {
        switch request.scope {
        case .account(let accountKey): previous[accountKey] != nil
        case .provider, .importedAccounts: !previous.isEmpty
        }
    }

    private func wasRemoved(
        provider: QuotaProvider,
        accountKey: String,
        aliases: [String: String],
        after generation: UInt64
    ) -> Bool {
        let canonicalKey = aliases[accountKey] ?? accountKey
        let keys = aliases.compactMap { alias, canonical in
            canonical == canonicalKey ? alias : nil
        } + [accountKey, canonicalKey]
        return keys.contains { key in
            let account = normalized(QuotaAccountID(provider: provider, accountKey: key))
            return accountRemovalGenerations[account, default: 0] > generation
        }
    }

    private func normalized(_ account: QuotaAccountID) -> QuotaAccountID {
        QuotaAccountID(provider: account.provider, accountKey: account.accountKey.lowercased())
    }

    private func recordFailure(for request: QuotaFetchRequest, at date: Date) {
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: date)
        let scope = retryScope(for: request)
        switch scope {
        case .provider(let provider): snapshot.issues[provider] = issue
        case .account(let account): snapshot.accountIssues[account] = issue
        }
        retryAfter[scope] = date.addingTimeInterval(retryDelay)
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func removeWaiter(_ waiterID: UUID, from operation: InFlight) {
        guard var current = inFlight[operation.request.provider], current.id == operation.id else {
            return
        }
        current.waiters.remove(waiterID)
        guard current.waiters.isEmpty else {
            inFlight[operation.request.provider] = current
            return
        }
        inFlight.removeValue(forKey: operation.request.provider)
        current.task.cancel()
        snapshot.refreshingProviders.remove(operation.request.provider)
        publish()
    }

    private func cancelAllInFlight() {
        for operation in inFlight.values {
            operation.task.cancel()
        }
        inFlight.removeAll()
        snapshot.refreshingProviders.removeAll()
    }
}
