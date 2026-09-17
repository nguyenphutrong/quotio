import Foundation
import QuotioDomain

public enum QuotaOperatingMode: Equatable, Sendable {
    case localProxy
    case monitor
}

public enum QuotaFetchScope: Equatable, Sendable {
    case provider
    case account(String)
    case importedAccounts(Set<String>)
}

public struct QuotaFetchRequest: Equatable, Sendable {
    public let provider: QuotaProvider
    public let scope: QuotaFetchScope
    public let mode: QuotaOperatingMode
    public let force: Bool

    public init(
        provider: QuotaProvider,
        scope: QuotaFetchScope = .provider,
        mode: QuotaOperatingMode,
        force: Bool = false
    ) {
        self.provider = provider
        self.scope = scope
        self.mode = mode
        self.force = force
    }
}

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
    public var accountIDs: [QuotaProvider: [String: String]]
    public var subscriptions: [QuotaProvider: [String: QuotaSubscriptionInfo]]
    public var issues: [QuotaProvider: QuotaRefreshIssue]
    public var accountIssues: [QuotaAccountID: QuotaRefreshIssue]
    public var refreshingProviders: Set<QuotaProvider>
    public var lastUpdated: Date?

    public init(
        quotas: [QuotaProvider: [String: ProviderQuota]] = [:],
        accountAliases: [QuotaProvider: [String: String]] = [:],
        accountIDs: [QuotaProvider: [String: String]] = [:],
        subscriptions: [QuotaProvider: [String: QuotaSubscriptionInfo]] = [:],
        issues: [QuotaProvider: QuotaRefreshIssue] = [:],
        accountIssues: [QuotaAccountID: QuotaRefreshIssue] = [:],
        refreshingProviders: Set<QuotaProvider> = [],
        lastUpdated: Date? = nil
    ) {
        self.quotas = quotas
        self.accountAliases = accountAliases
        self.accountIDs = accountIDs
        self.subscriptions = subscriptions
        self.issues = issues
        self.accountIssues = accountIssues
        self.refreshingProviders = refreshingProviders
        self.lastUpdated = lastUpdated
    }
}

public protocol QuotaCoordinating: Sendable {
    var snapshot: QuotaSnapshot { get async }

    func states() async -> AsyncStream<QuotaSnapshot>
    func bootstrap(mode: QuotaOperatingMode) async -> QuotaSnapshot
    func refresh(_ request: QuotaFetchRequest) async -> QuotaSnapshot
    func refreshAll(
        mode: QuotaOperatingMode,
        providers: Set<QuotaProvider>?,
        force: Bool
    ) async -> QuotaSnapshot
    func replaceQuotas(
        _ quotas: [String: ProviderQuota],
        for provider: QuotaProvider,
        mode: QuotaOperatingMode
    ) async
    func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) async
    func cancel(provider: QuotaProvider) async
    func cancelForTermination() async
}
