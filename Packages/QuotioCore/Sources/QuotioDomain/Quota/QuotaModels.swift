import Foundation

public struct QuotaProvider: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String
    public static let claude = Self(rawValue: "claude")!
    public static let codex = Self(rawValue: "codex")!
    public static let qwen = Self(rawValue: "qwen")!
    public static let iflow = Self(rawValue: "iflow")!
    public static let antigravity = Self(rawValue: "antigravity")!
    public static let vertex = Self(rawValue: "vertexai")!
    public static let kiro = Self(rawValue: "kiro")!
    public static let copilot = Self(rawValue: "copilot")!
    public static let cursor = Self(rawValue: "cursor")!
    public static let factoryDroid = Self(rawValue: "factory")!
    public static let devin = Self(rawValue: "devin-desktop")!
    public static let grok = Self(rawValue: "grok")!
    public static let openRouter = Self(rawValue: "openrouter")!
    public static let amp = Self(rawValue: "amp")!
    public static let trae = Self(rawValue: "trae")!
    public static let glm = Self(rawValue: "zai")!
    public static let warp = Self(rawValue: "warp")!
    public static let clinePass = Self(rawValue: "clinepass")!
    public static let allCases: [Self] = [.claude, .codex, .qwen, .iflow, .antigravity, .vertex, .kiro, .copilot, .cursor, .factoryDroid, .devin, .grok, .openRouter, .amp, .trae, .glm, .warp, .clinePass]

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
              rawValue.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let provider = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid provider ID")
        }
        self = provider
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: String { rawValue }

    public var supportsQuotaOnlyMode: Bool {
        switch self {
        case .qwen, .iflow, .trae:
            false
        default:
            true
        }
    }

    public var usesBrowserAuth: Bool {
        self == .cursor || self == .trae
    }

    public var usesCLIQuota: Bool {
        self == .claude || self == .codex
    }

    public var supportsManualAuth: Bool {
        switch self {
        case .cursor, .trae, .devin, .grok, .glm, .clinePass:
            false
        default:
            true
        }
    }

    public var isImportedFromLocalIDE: Bool {
        usesBrowserAuth && !supportsManualAuth
    }

    public var usesAPIKeyAuth: Bool {
        switch self {
        case .glm, .warp, .clinePass, .factoryDroid, .openRouter, .amp:
            true
        default:
            false
        }
    }

    public var isQuotaTrackingOnly: Bool {
        switch self {
        case .cursor, .trae, .factoryDroid, .devin, .grok, .openRouter, .amp, .warp:
            true
        default:
            false
        }
    }

    public var supportsLocalProxySetup: Bool {
        supportsManualAuth && !isQuotaTrackingOnly
    }
}

public struct QuotaAccountID: Hashable, Sendable {
    public let provider: QuotaProvider
    public let accountKey: String

    public init(provider: QuotaProvider, accountKey: String) {
        self.provider = provider
        self.accountKey = accountKey
    }
}

public struct QuotaMetricUnit: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String
    public static let usd = Self(rawValue: "usd")!
    public static let credits = Self(rawValue: "credits")!
    public static let requests = Self(rawValue: "requests")!
    public static let searches = Self(rawValue: "searches")!

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let known = ["usd", "credits", "requests", "searches"]
        self.rawValue = known.contains(value.lowercased()) ? value.lowercased() : value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let unit = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty metric unit")
        }
        self = unit
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum QuotaAmountSemantics: String, Codable, Equatable, Sendable {
    case balance
    case spent
}

public enum QuotaMetricPresentation: Codable, Equatable, Sendable {
    case progress(used: Double, limit: Double, unit: QuotaMetricUnit)
    case amount(value: Double, unit: QuotaMetricUnit, semantics: QuotaAmountSemantics)
    case status(text: String)
}

/// How finely a metric's reset time is known, when not to the second.
public enum QuotaResetPrecision: String, Codable, Equatable, Sendable {
    /// The day is known; the time of day is midnight UTC by convention.
    case day
}

public struct QuotaMetric: Codable, Equatable, Identifiable, Sendable {
    public let group: String?
    public let name: String
    public let backendID: String?
    public let percentage: Double
    public let resetTime: String
    public var presentation: QuotaMetricPresentation?
    public var used: Int?
    public var limit: Int?
    public var remaining: Int?
    public var tooltip: String?
    /// Length of one quota period, when known. Pace needs it to place the expected-remaining mark.
    public var windowDuration: TimeInterval?
    /// Nil when `resetTime` is exact.
    public var resetPrecision: QuotaResetPrecision?

    public var id: String { backendID ?? name }
    public var usedPercentage: Double { 100 - percentage }

    public init(
        name: String,
        id: String? = nil,
        percentage: Double,
        resetTime: String,
        presentation: QuotaMetricPresentation? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        tooltip: String? = nil,
        group: String? = nil,
        windowDuration: TimeInterval? = nil,
        resetPrecision: QuotaResetPrecision? = nil
    ) {
        self.group = group
        self.name = name
        self.backendID = id
        self.percentage = percentage
        self.resetTime = resetTime
        self.presentation = presentation
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.tooltip = tooltip
        self.windowDuration = windowDuration
        self.resetPrecision = resetPrecision
    }
}

public struct QuotaAnalytics: Codable, Equatable, Sendable {
    public var trend: [QuotaAnalyticsPoint]
    public var rows: [QuotaAnalyticsRow]
    public var note: String?

    public var isEmpty: Bool {
        trend.isEmpty && rows.isEmpty && (note?.isEmpty ?? true)
    }

    public init(
        trend: [QuotaAnalyticsPoint] = [],
        rows: [QuotaAnalyticsRow] = [],
        note: String? = nil
    ) {
        self.trend = trend
        self.rows = rows
        self.note = note
    }

    public func merging(_ other: QuotaAnalytics?) -> QuotaAnalytics {
        guard let other, !other.isEmpty else { return self }
        var mergedRows = rows
        var seen = Set(rows.map(\.id))
        for row in other.rows where seen.insert(row.id).inserted {
            mergedRows.append(row)
        }
        return QuotaAnalytics(
            trend: other.trend.isEmpty ? trend : other.trend,
            rows: mergedRows,
            note: other.note ?? note
        )
    }
}

public struct QuotaAnalyticsPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { date }
    public var date: String
    public var value: Double
    public var label: String
    public var valueLabel: String

    public init(date: String, value: Double, label: String, valueLabel: String) {
        self.date = date
        self.value = value
        self.label = label
        self.valueLabel = valueLabel
    }
}

public struct QuotaAnalyticsRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var isAvailable: Bool

    public init(id: String, title: String, value: String, isAvailable: Bool = true) {
        self.id = id
        self.title = title
        self.value = value
        self.isAvailable = isAvailable
    }
}

public struct QuotaSummary: Codable, Equatable, Sendable {
    public struct Totals: Codable, Equatable, Sendable {
        public let lowest: Double?
        public let average: Double?
        public init(lowest: Double?, average: Double?) {
            self.lowest = lowest
            self.average = average
        }
    }
    public struct Metric: Codable, Equatable, Sendable {
        public let displayName: String
        public let remainingPercent: Double?
        public init(displayName: String, remainingPercent: Double?) {
            self.displayName = displayName
            self.remainingPercent = remainingPercent
        }
    }
    public let sessionOnly: Totals
    public let combined: Totals
    public let pair: [Metric]
    public init(sessionOnly: Totals, combined: Totals, pair: [Metric]) {
        self.sessionOnly = sessionOnly
        self.combined = combined
        self.pair = pair
    }
}

public struct ProviderQuota: Codable, Equatable, Sendable {
    public var summary: QuotaSummary?
    public var models: [QuotaMetric]
    public var lastUpdated: Date
    public var isForbidden: Bool
    public var planType: String?
    public var tokenExpiresAt: Date?
    public var analytics: QuotaAnalytics?
    public var accountDisplayName: String?

    public init(
        models: [QuotaMetric] = [],
        lastUpdated: Date = Date(),
        isForbidden: Bool = false,
        planType: String? = nil,
        tokenExpiresAt: Date? = nil,
        analytics: QuotaAnalytics? = nil,
        accountDisplayName: String? = nil,
        summary: QuotaSummary? = nil
    ) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
        self.tokenExpiresAt = tokenExpiresAt
        self.analytics = analytics
        self.summary = summary
        self.accountDisplayName = accountDisplayName
    }
}

public struct QuotaSubscriptionTier: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let privacyNotice: QuotaPrivacyNotice?
    public let isDefault: Bool?
    public let upgradeSubscriptionUri: String?
    public let upgradeSubscriptionText: String?
    public let upgradeSubscriptionType: String?
    public let userDefinedCloudaicompanionProject: Bool?

    public init(
        id: String,
        name: String,
        description: String,
        privacyNotice: QuotaPrivacyNotice?,
        isDefault: Bool?,
        upgradeSubscriptionUri: String?,
        upgradeSubscriptionText: String?,
        upgradeSubscriptionType: String?,
        userDefinedCloudaicompanionProject: Bool?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.privacyNotice = privacyNotice
        self.isDefault = isDefault
        self.upgradeSubscriptionUri = upgradeSubscriptionUri
        self.upgradeSubscriptionText = upgradeSubscriptionText
        self.upgradeSubscriptionType = upgradeSubscriptionType
        self.userDefinedCloudaicompanionProject = userDefinedCloudaicompanionProject
    }
}

public struct QuotaPrivacyNotice: Codable, Equatable, Sendable {
    public let showNotice: Bool?
    public let noticeText: String?

    public init(showNotice: Bool?, noticeText: String?) {
        self.showNotice = showNotice
        self.noticeText = noticeText
    }
}

public struct QuotaSubscriptionInfo: Codable, Equatable, Sendable {
    public let currentTier: QuotaSubscriptionTier?
    public let allowedTiers: [QuotaSubscriptionTier]?
    public let cloudaicompanionProject: String?
    public let gcpManaged: Bool?
    public let upgradeSubscriptionUri: String?
    public let paidTier: QuotaSubscriptionTier?

    public var effectiveTier: QuotaSubscriptionTier? { paidTier ?? currentTier }
    public var tierId: String { effectiveTier?.id ?? "unknown" }
    public var isPaidTier: Bool {
        guard let id = effectiveTier?.id else { return false }
        return id.contains("pro") || id.contains("ultra")
    }
    public var canUpgrade: Bool { effectiveTier?.upgradeSubscriptionUri != nil }
    public var upgradeURL: URL? {
        effectiveTier?.upgradeSubscriptionUri.flatMap(URL.init(string:))
    }

    public init(
        currentTier: QuotaSubscriptionTier?,
        allowedTiers: [QuotaSubscriptionTier]?,
        cloudaicompanionProject: String?,
        gcpManaged: Bool?,
        upgradeSubscriptionUri: String?,
        paidTier: QuotaSubscriptionTier?
    ) {
        self.currentTier = currentTier
        self.allowedTiers = allowedTiers
        self.cloudaicompanionProject = cloudaicompanionProject
        self.gcpManaged = gcpManaged
        self.upgradeSubscriptionUri = upgradeSubscriptionUri
        self.paidTier = paidTier
    }
}

public enum QuotaPolicy {
    public static func mergeImportedIDEQuotas(
        fetched: [String: ProviderQuota],
        into existing: [String: ProviderQuota]
    ) -> [String: ProviderQuota] {
        guard !existing.isEmpty else { return existing }
        var merged = existing
        for (accountKey, quota) in fetched where existing[accountKey] != nil {
            merged[accountKey] = quota
        }
        return merged
    }

    public static func canonicalizedAccounts(
        _ quotas: [String: ProviderQuota],
        aliases: [String: String]
    ) -> [String: ProviderQuota] {
        var result = quotas
        for (alias, canonical) in aliases where alias != canonical {
            guard let aliasQuota = result.removeValue(forKey: alias) else { continue }
            if result[canonical].map({ $0.lastUpdated <= aliasQuota.lastUpdated }) ?? true {
                result[canonical] = aliasQuota
            }
        }
        return result
    }

    public static func lastUpdated(
        for account: QuotaAccountID,
        in quotas: [QuotaProvider: [String: ProviderQuota]]
    ) -> Date? {
        quotas[account.provider]?[account.accountKey]?.lastUpdated
    }

    public static func lowestAvailablePercentage(in quota: ProviderQuota) -> Double {
        quota.models.lazy.map(\.percentage).filter { $0 >= 0 }.min()
            ?? quota.models.first?.percentage
            ?? -1
    }
}
