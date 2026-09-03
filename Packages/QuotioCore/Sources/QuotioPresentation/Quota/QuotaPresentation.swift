import Foundation
import QuotioDomain

public enum AntigravityModelGroup: String, CaseIterable, Identifiable, Sendable {
    case claude = "Claude"
    case geminiPro = "Gemini Pro"
    case geminiFlash = "Gemini Flash"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public var icon: String {
        switch self {
        case .claude: "brain.head.profile"
        case .geminiPro: "sparkles"
        case .geminiFlash: "bolt.fill"
        }
    }

    public static func group(for modelName: String) -> AntigravityModelGroup? {
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

public struct GroupedModelQuota: Identifiable, Sendable {
    public let group: AntigravityModelGroup
    public let models: [QuotaMetric]

    public var id: String { group.id }
    public var percentage: Double { models.map(\.percentage).min() ?? 0 }
    public var displayName: String { group.displayName }

    public var formattedPercentage: String {
        percentage == percentage.rounded()
            ? String(format: "%.0f%%", percentage)
            : String(format: "%.2f%%", percentage)
    }

    public var resetTime: String {
        models.compactMap { Self.parseISO8601Date($0.resetTime) }
            .min()
            .map { ISO8601DateFormatter().string(from: $0) } ?? ""
    }

    public var formattedResetTime: String {
        Self.relativeResetTime(resetTime)
    }

    public init(group: AntigravityModelGroup, models: [QuotaMetric]) {
        self.group = group
        self.models = models
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }

    fileprivate static func relativeResetTime(_ value: String) -> String {
        guard !value.isEmpty, let date = parseISO8601Date(value) else { return "—" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "now" }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24
        if days > 0 {
            return remainingHours > 0 ? "\(days)d \(remainingHours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }
}

@MainActor
public extension QuotaMetricUnit {
    func format(_ value: Double) -> String {
        switch self {
        case .usd:
            value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .credits:
            String.localizedStringWithFormat("quota.metric.unit.credits".localizedStatic(), value)
        case .requests:
            String.localizedStringWithFormat("quota.metric.unit.requests".localizedStatic(), value)
        case .searches:
            String.localizedStringWithFormat("quota.metric.unit.searches".localizedStatic(), value)
        }
    }
}

@MainActor
public extension QuotaMetric {
    var formattedPercentage: String {
        guard percentage >= 0 else { return "—" }
        return percentage == percentage.rounded()
            ? String(format: "%.0f%%", percentage)
            : String(format: "%.2f%%", percentage)
    }

    var formattedUsage: String? {
        if let presentation {
            switch presentation {
            case .progress(let used, let limit, let unit):
                return unit.format(used) + " / " + unit.format(limit)
            case .amount(let value, let unit, let semantics):
                let key = semantics == .balance ? "quota.metric.balanceValue" : "quota.metric.spentValue"
                return String(format: key.localizedStatic(), unit.format(value))
            case .status(let text):
                if text == "grok-disabled" { return "grok.status.disabled".localizedStatic() }
                if text.hasPrefix("grok-cap:") {
                    return String(
                        format: "grok.status.cap".localizedStatic(),
                        String(text.dropFirst("grok-cap:".count))
                    )
                }
                if text == "legacy-billing" { return "factory.status.legacyBilling".localizedStatic() }
                return text
            }
        }
        guard let used else { return nil }
        if let limit, limit > 0 { return "\(used)/\(limit)" }
        return "\(used) used"
    }

    var isStandaloneMetric: Bool {
        guard let presentation else { return false }
        return switch presentation {
        case .amount, .status: true
        case .progress: false
        }
    }

    var modelGroup: AntigravityModelGroup? {
        AntigravityModelGroup.group(for: name)
    }

    var displayName: String {
        switch name {
        case "gemini-3-pro-high", "gemini-3-pro": "Gemini 3 Pro"
        case "gemini-3-flash", "gemini-3-flash-high": "Gemini 3 Flash"
        case "gemini-3-pro-image", "gemini-3-flash-image": "Gemini 3 Image"
        case "claude-sonnet-4-5": "Claude Sonnet 4.5"
        case "claude-sonnet-4-5-thinking": "Claude Sonnet 4.5 (Thinking)"
        case "claude-opus-4": "Claude Opus 4"
        case "claude-opus-4-5": "Claude Opus 4.5"
        case "claude-opus-4-5-thinking": "Claude Opus 4.5 (Thinking)"
        case "claude-opus-4-6": "Claude Opus 4.6"
        case "claude-opus-4-6-thinking": "Claude Opus 4.6 (Thinking)"
        case "claude-4-sonnet": "Claude 4 Sonnet"
        case "claude-4-opus": "Claude 4 Opus"
        case "antigravity-gemini-session": "Gemini Session"
        case "antigravity-gemini-weekly": "Gemini Weekly"
        case "antigravity-claude-gpt-session": "Claude/GPT Session"
        case "antigravity-claude-gpt-weekly": "Claude/GPT Weekly"
        case "codex-session": "Session"
        case "codex-weekly": "Weekly"
        case "codex-spark": "Codex Spark"
        case "codex-spark-weekly": "Codex Spark Weekly"
        case let value where value.hasPrefix("codex-"):
            value.dropFirst("codex-".count).split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        case "copilot-chat": "Chat"
        case "copilot-completions": "Completions"
        case "copilot-premium": "Premium"
        case "plan-usage": "Plan Usage"
        case "on-demand": "On-Demand"
        case "cursor-usage", "trae-usage", "windsurf-usage": "Usage"
        case "five-hour-session": "Session"
        case "seven-day-weekly", "weekly-usage": "Weekly"
        case "seven-day-sonnet", "sonnet-only": "Sonnet"
        case "seven-day-opus": "Opus"
        case "extra-usage": "Extra"
        case "gemini-quota": "Gemini"
        case "premium-fast": "Fast Requests"
        case "premium-slow": "Slow Requests"
        case "advanced-model": "Advanced"
        case "auto-completion": "Completions"
        case "warp-usage": "warp.credits.label".localizedStatic()
        case "clinepass-five-hour": "clinepass.quota.fiveHour".localizedStatic()
        case "clinepass-weekly": "clinepass.quota.weekly".localizedStatic()
        case "clinepass-monthly": "clinepass.quota.monthly".localizedStatic()
        case "zai-session": "quota.metric.session".localizedStatic()
        case "zai-daily", "devin-daily": "quota.metric.daily".localizedStatic()
        case "zai-weekly", "devin-weekly", "grok-weekly": "quota.metric.weekly".localizedStatic()
        case "zai-monthly": "quota.metric.monthly".localizedStatic()
        case "zai-web-searches": "quota.metric.webSearches".localizedStatic()
        case "devin-extra-balance", "factory-extra-balance": "quota.metric.extraBalance".localizedStatic()
        case "grok-extra-usage": "quota.metric.extraUsage".localizedStatic()
        case "factory-standard-five-hour": "factory.quota.standardFiveHour".localizedStatic()
        case "factory-standard-weekly": "factory.quota.standardWeekly".localizedStatic()
        case "factory-standard-monthly": "factory.quota.standardMonthly".localizedStatic()
        case "factory-core-five-hour": "factory.quota.coreFiveHour".localizedStatic()
        case "factory-core-weekly": "factory.quota.coreWeekly".localizedStatic()
        case "factory-core-monthly": "factory.quota.coreMonthly".localizedStatic()
        case "factory-billing-mode": "factory.quota.billingMode".localizedStatic()
        case "openrouter-credits": "quota.metric.credits".localizedStatic()
        case "openrouter-balance": "quota.metric.balance".localizedStatic()
        case "openrouter-today": "quota.metric.today".localizedStatic()
        case "openrouter-week": "quota.metric.thisWeek".localizedStatic()
        case "openrouter-month": "quota.metric.thisMonth".localizedStatic()
        case "openrouter-key-limit": "quota.metric.keyLimit".localizedStatic()
        case "amp-free": "amp.quota.free".localizedStatic()
        case "amp-agent-usage": "amp.quota.agent".localizedStatic()
        case "amp-orb-usage": "amp.quota.orb".localizedStatic()
        case "amp-individual-credits": "amp.quota.individualCredits".localizedStatic()
        case let value where value.hasPrefix("amp-workspace-"):
            "amp.quota.workspaceCredits".localizedStatic()
        case let value where value.hasPrefix("warp-bonus-"):
            "Bonus \((Int(value.dropFirst("warp-bonus-".count)) ?? 0) + 1)"
        default: name
        }
    }

    var formattedResetTime: String {
        GroupedModelQuota.relativeResetTime(resetTime)
    }
}

@MainActor
public extension ProviderQuota {
    var formattedTokenExpiry: String? {
        guard let tokenExpiresAt else { return nil }
        guard tokenExpiresAt.timeIntervalSinceNow > 0 else { return "Expired" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return "Token expires \(formatter.string(from: tokenExpiresAt))"
    }

    var planDisplayName: String? {
        guard let plan = planType?.lowercased() else { return nil }
        return switch plan {
        case "openrouter-free": "openrouter.plan.freeTier".localizedStatic()
        case "openrouter-pay-as-you-go": "openrouter.plan.payAsYouGo".localizedStatic()
        case "guest": "Guest"
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "pro": "Pro"
        case "free_workspace": "Free Workspace"
        case "team": "Team"
        case "business": "Business"
        case "education": "Education"
        case "quorum": "Quorum"
        case "k12": "K-12"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        default: planType?.capitalized
        }
    }

    var groupedModels: [GroupedModelQuota] {
        let grouped = Dictionary(grouping: models.compactMap { model in
            model.modelGroup.map { ($0, model) }
        }, by: \.0).mapValues { $0.map(\.1) }
        return AntigravityModelGroup.allCases.compactMap { group in
            grouped[group].map { GroupedModelQuota(group: group, models: $0) }
        }
    }

    var hasGroupedModels: Bool { models.contains { $0.modelGroup != nil } }
}

public extension QuotaSubscriptionInfo {
    var tierDisplayName: String { effectiveTier?.name ?? "Unknown" }
    var tierDescription: String { effectiveTier?.description ?? "" }
}

public enum FactoryDroidQuotaGroup: String, CaseIterable, Identifiable, Sendable {
    case standard
    case core

    public var id: String { rawValue }

    @MainActor
    public var title: String {
        switch self {
        case .standard: "factory.quota.group.standard".localizedStatic()
        case .core: "factory.quota.group.core".localizedStatic()
        }
    }

    fileprivate var modelPrefix: String { "factory-\(rawValue)-" }
}

public struct FactoryDroidQuotaSection: Identifiable, Sendable {
    public let group: FactoryDroidQuotaGroup
    public let models: [QuotaMetric]

    public var id: FactoryDroidQuotaGroup { group }
    @MainActor public var title: String { group.title }

    public init(group: FactoryDroidQuotaGroup, models: [QuotaMetric]) {
        self.group = group
        self.models = models
    }

    public static func sections(from models: [QuotaMetric]) -> [FactoryDroidQuotaSection] {
        FactoryDroidQuotaGroup.allCases.compactMap { group in
            let matching = models.filter { $0.name.hasPrefix(group.modelPrefix) }
            return matching.isEmpty ? nil : FactoryDroidQuotaSection(group: group, models: matching)
        }
    }
}
