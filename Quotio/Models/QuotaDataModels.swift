//
//  QuotaDataModels.swift
//  Quotio
//

import Foundation

// MARK: - Model Group

nonisolated enum AntigravityModelGroup: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case geminiPro = "Gemini Pro"
    case geminiFlash = "Gemini Flash"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .geminiPro: return "sparkles"
        case .geminiFlash: return "bolt.fill"
        }
    }

    static func group(for modelName: String) -> AntigravityModelGroup? {
        let name = modelName.lowercased()

        if name.contains("claude") || name.contains("gpt") || name.contains("oss") {
            return .claude
        }

        if name.contains("gemini") && name.contains("pro") {
            return .geminiPro
        }

        if name.contains("gemini") && name.contains("flash") {
            return .geminiFlash
        }

        return nil
    }
}

nonisolated struct GroupedModelQuota: Identifiable, Sendable {
    let group: AntigravityModelGroup
    let models: [ModelQuota]

    var id: String { group.id }

    var percentage: Double {
        models.map(\.percentage).min() ?? 0
    }

    var formattedPercentage: String {
        if percentage == percentage.rounded() {
            return String(format: "%.0f%%", percentage)
        }
        return String(format: "%.2f%%", percentage)
    }

    var resetTime: String {
        models.compactMap { model -> Date? in
            parseISO8601Date(model.resetTime)
        }.min().map { date in
            ISO8601DateFormatter().string(from: date)
        } ?? ""
    }

    var formattedResetTime: String {
        guard !resetTime.isEmpty,
              let date = parseISO8601Date(resetTime) else {
            return "—"
        }

        return formatResetInterval(to: date)
    }

    private func parseISO8601Date(_ dateString: String) -> Date? {
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        return isoFormatterWithFractional.date(from: dateString)
            ?? isoFormatterStandard.date(from: dateString)
    }

    var displayName: String { group.displayName }
}

// MARK: - Quota Models

nonisolated struct ModelQuota: Codable, Identifiable, Sendable {
    let name: String
    let percentage: Double
    let resetTime: String
    var used: Int?
    var limit: Int?
    var remaining: Int?
    var tooltip: String?

    var id: String { name }

    var usedPercentage: Double {
        100 - percentage
    }

    var formattedPercentage: String {
        if percentage < 0 {
            return "—"
        }
        if percentage == percentage.rounded() {
            return String(format: "%.0f%%", percentage)
        }
        return String(format: "%.2f%%", percentage)
    }

    var formattedUsage: String? {
        guard let used else { return nil }
        if let limit, limit > 0 {
            return "\(used)/\(limit)"
        }
        return "\(used) used"
    }

    var modelGroup: AntigravityModelGroup? {
        AntigravityModelGroup.group(for: name)
    }

    var displayName: String {
        switch name {
        case "gemini-3-pro-high": return "Gemini 3 Pro"
        case "gemini-3-pro": return "Gemini 3 Pro"
        case "gemini-3-flash": return "Gemini 3 Flash"
        case "gemini-3-flash-high": return "Gemini 3 Flash"
        case "gemini-3-pro-image": return "Gemini 3 Image"
        case "gemini-3-flash-image": return "Gemini 3 Image"
        case "claude-sonnet-4-5": return "Claude Sonnet 4.5"
        case "claude-sonnet-4-5-thinking": return "Claude Sonnet 4.5 (Thinking)"
        case "claude-opus-4": return "Claude Opus 4"
        case "claude-opus-4-5": return "Claude Opus 4.5"
        case "claude-opus-4-5-thinking": return "Claude Opus 4.5 (Thinking)"
        case "claude-opus-4-6": return "Claude Opus 4.6"
        case "claude-opus-4-6-thinking": return "Claude Opus 4.6 (Thinking)"
        case "claude-4-sonnet": return "Claude 4 Sonnet"
        case "claude-4-opus": return "Claude 4 Opus"
        case "codex-session": return "Session"
        case "codex-weekly": return "Weekly"
        case "copilot-chat": return "Chat"
        case "copilot-completions": return "Completions"
        case "copilot-premium": return "Premium"
        case "plan-usage": return "Plan Usage"
        case "on-demand": return "On-Demand"
        case "cursor-usage": return "Usage"
        case "five-hour-session": return "Session"
        case "seven-day-weekly": return "Weekly"
        case "seven-day-sonnet": return "Sonnet"
        case "seven-day-opus": return "Opus"
        case "extra-usage": return "Extra"
        case "weekly-usage": return "Weekly"
        case "sonnet-only": return "Sonnet"
        case "gemini-quota": return "Gemini"
        case "trae-usage": return "Usage"
        case "premium-fast": return "Fast Requests"
        case "premium-slow": return "Slow Requests"
        case "advanced-model": return "Advanced"
        case "auto-completion": return "Completions"
        case "windsurf-usage": return "Usage"
        case "warp-usage": return "warp.credits.label".localizedStatic()
        case let name where name.hasPrefix("warp-bonus-"):
            let index = Int(String(name.dropFirst("warp-bonus-".count))) ?? 0
            return "Bonus \(index + 1)"
        default:
            return name
        }
    }

    var formattedResetTime: String {
        guard !resetTime.isEmpty,
              let date = parseISO8601Date(resetTime) else {
            return "—"
        }

        return formatResetInterval(to: date)
    }

    private func parseISO8601Date(_ dateString: String) -> Date? {
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        return isoFormatterWithFractional.date(from: dateString)
            ?? isoFormatterStandard.date(from: dateString)
    }
}

nonisolated struct ProviderQuotaData: Codable, Sendable {
    var models: [ModelQuota]
    var lastUpdated: Date
    var isForbidden: Bool
    var planType: String?
    var tokenExpiresAt: Date?

    init(
        models: [ModelQuota] = [],
        lastUpdated: Date = Date(),
        isForbidden: Bool = false,
        planType: String? = nil,
        tokenExpiresAt: Date? = nil
    ) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
        self.tokenExpiresAt = tokenExpiresAt
    }

    var formattedTokenExpiry: String? {
        guard let expiresAt = tokenExpiresAt else { return nil }

        let interval = expiresAt.timeIntervalSince(Date())
        if interval <= 0 {
            return "Expired"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone.current
        return "Token expires \(formatter.string(from: expiresAt))"
    }

    var planDisplayName: String? {
        guard let plan = planType?.lowercased() else { return nil }
        switch plan {
        case "guest": return "Guest"
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free_workspace": return "Free Workspace"
        case "team": return "Team"
        case "business": return "Business"
        case "education": return "Education"
        case "quorum": return "Quorum"
        case "k12": return "K-12"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return planType?.capitalized
        }
    }

    var groupedModels: [GroupedModelQuota] {
        var grouped: [AntigravityModelGroup: [ModelQuota]] = [:]

        for model in models {
            guard let group = model.modelGroup else { continue }
            grouped[group, default: []].append(model)
        }

        return AntigravityModelGroup.allCases.compactMap { group in
            guard let models = grouped[group], !models.isEmpty else { return nil }
            return GroupedModelQuota(group: group, models: models)
        }
    }

    var hasGroupedModels: Bool {
        models.contains { $0.modelGroup != nil }
    }
}

// MARK: - Subscription Info Models

nonisolated struct SubscriptionTier: Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let privacyNotice: PrivacyNotice?
    let isDefault: Bool?
    let upgradeSubscriptionUri: String?
    let upgradeSubscriptionText: String?
    let upgradeSubscriptionType: String?
    let userDefinedCloudaicompanionProject: Bool?
}

nonisolated struct PrivacyNotice: Codable, Sendable {
    let showNotice: Bool?
    let noticeText: String?
}

nonisolated struct SubscriptionInfo: Codable, Sendable {
    let currentTier: SubscriptionTier?
    let allowedTiers: [SubscriptionTier]?
    let cloudaicompanionProject: String?
    let gcpManaged: Bool?
    let upgradeSubscriptionUri: String?
    let paidTier: SubscriptionTier?

    private var effectiveTier: SubscriptionTier? {
        paidTier ?? currentTier
    }

    var tierDisplayName: String {
        effectiveTier?.name ?? "Unknown"
    }

    var tierDescription: String {
        effectiveTier?.description ?? ""
    }

    var tierId: String {
        effectiveTier?.id ?? "unknown"
    }

    var isPaidTier: Bool {
        guard let id = effectiveTier?.id else { return false }
        return id.contains("pro") || id.contains("ultra")
    }

    var canUpgrade: Bool {
        effectiveTier?.upgradeSubscriptionUri != nil
    }

    var upgradeURL: URL? {
        guard let uri = effectiveTier?.upgradeSubscriptionUri else { return nil }
        return URL(string: uri)
    }
}

nonisolated private func formatResetInterval(to date: Date) -> String {
    let interval = date.timeIntervalSince(Date())

    if interval <= 0 {
        return "now"
    }

    let totalMinutes = Int(interval / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let days = hours / 24
    let remainingHours = hours % 24

    if days > 0 {
        if remainingHours > 0 {
            return "\(days)d \(remainingHours)h"
        }
        return "\(days)d"
    } else if hours > 0 {
        if minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(hours)h"
    } else {
        return "\(max(1, minutes))m"
    }
}
