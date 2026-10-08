public struct QuotioHostSettings: Decodable, Sendable {
    public let revision: String
    public let enabledProviders: [String]
    public let disabledProviders: [String]
    public let automaticallyDiscoverLogins: Bool
    public let refreshInterval: Int
    public let quotaHistoryEnabled: Bool?
    public let overridden: [String]
}
