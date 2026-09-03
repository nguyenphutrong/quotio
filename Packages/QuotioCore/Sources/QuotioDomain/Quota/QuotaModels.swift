import Foundation

public enum QuotaProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case qwen
    case iflow
    case antigravity
    case vertex
    case kiro
    case copilot = "github-copilot"
    case cursor
    case factoryDroid = "factory-droid"
    case devin
    case grok
    case openRouter = "openrouter"
    case amp
    case trae
    case glm
    case warp
    case clinePass = "clinepass"

    public var id: String { rawValue }

    public var supportsQuotaOnlyMode: Bool {
        switch self {
        case .qwen, .iflow, .vertex:
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

    public var cliAgent: CLIAgent? {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCLI
        default: nil
        }
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

public enum QuotaMetricUnit: String, Codable, Equatable, Sendable {
    case usd
    case credits
    case requests
    case searches
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

public struct QuotaMetric: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let percentage: Double
    public let resetTime: String
    public var presentation: QuotaMetricPresentation?
    public var used: Int?
    public var limit: Int?
    public var remaining: Int?
    public var tooltip: String?

    public var id: String { name }
    public var usedPercentage: Double { 100 - percentage }

    public init(
        name: String,
        percentage: Double,
        resetTime: String,
        presentation: QuotaMetricPresentation? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        tooltip: String? = nil
    ) {
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.presentation = presentation
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.tooltip = tooltip
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

public struct ProviderQuota: Codable, Equatable, Sendable {
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
        accountDisplayName: String? = nil
    ) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
        self.tokenExpiresAt = tokenExpiresAt
        self.analytics = analytics
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
