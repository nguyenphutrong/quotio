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

public enum QuotaCredentialAvailability: Equatable, Sendable {
    case unknown
    case present
    case missing
}

public struct QuotaProviderOutput: Sendable {
    public var quotas: [String: ProviderQuota]
    public var subscriptions: [String: QuotaSubscriptionInfo]
    public var credentialAvailability: QuotaCredentialAvailability
    public var accountAliases: [String: String]

    public init(
        quotas: [String: ProviderQuota],
        subscriptions: [String: QuotaSubscriptionInfo] = [:],
        credentialAvailability: QuotaCredentialAvailability = .unknown,
        accountAliases: [String: String] = [:]
    ) {
        self.quotas = quotas
        self.subscriptions = subscriptions
        self.credentialAvailability = credentialAvailability
        self.accountAliases = accountAliases
    }
}

public protocol QuotaFetching: Sendable {
    var provider: QuotaProvider { get }
    func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput
}

public protocol QuotaSnapshotStoring: Sendable {
    func load(for mode: QuotaOperatingMode) async -> QuotaSnapshot
    func save(_ snapshot: QuotaSnapshot, for mode: QuotaOperatingMode) async
}

public struct QuotaProviderRegistry: Sendable {
    private let fetchers: [QuotaProvider: any QuotaFetching]

    public init(_ fetchers: [any QuotaFetching]) {
        self.fetchers = fetchers.reduce(into: [:]) { result, fetcher in
            result[fetcher.provider] = fetcher
        }
    }

    public var providers: Set<QuotaProvider> {
        Set(fetchers.keys)
    }

    public func fetcher(for provider: QuotaProvider) -> (any QuotaFetching)? {
        fetchers[provider]
    }
}
