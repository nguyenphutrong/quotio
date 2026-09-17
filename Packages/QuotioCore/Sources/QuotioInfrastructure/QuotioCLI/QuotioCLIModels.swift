import Foundation
import QuotioApplication
import QuotioDomain

struct QuotioCLIUsageReport: Decodable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let providers: [QuotioCLIProviderUsage]
    let failures: [QuotioCLIUsageFailure]
}

struct QuotioCLIProviderUsage: Decodable, Sendable {
    struct Identity: Decodable, Sendable {
        let id: String
        let label: String
        let plan: String?
    }

    let provider: String
    let account: Identity
    let accountRef: QuotioCLIAccountReference?
    let windows: [QuotioCLIUsageWindow]
    let antigravitySubscription: QuotioCLISubscription?
    let resetCredits: QuotioCLIResetCredits?
    let codexProfile: QuotioCLICodexProfile?
    let codexResetCredits: QuotioCLICodexResetCredits?
}

struct QuotioCLIResetCredits: Decodable, Sendable {
    let availableCount: UInt64
    let fetchedAt: Date
}

struct QuotioCLICodexProfile: Decodable, Sendable {
    struct DailyUsage: Decodable, Sendable {
        let date: String
        let tokens: UInt64
    }

    let dailyUsage: [DailyUsage]
    let latest30BucketsTokens: UInt64
    let lifetimeTokens: UInt64?
    let peakDailyTokens: UInt64?
    let longestRunningTurnSeconds: UInt64?
    let currentStreakDays: UInt64?
    let longestStreakDays: UInt64?
    let fetchedAt: Date
}

struct QuotioCLICodexResetCredits: Decodable, Sendable {
    struct Credit: Decodable, Sendable {
        let id: String
        let expiresAt: Date?
    }

    let availableCount: UInt64
    let credits: [Credit]
    let fetchedAt: Date
}

struct QuotioCLIAccountReference: Decodable, Sendable {
    let origin: String?
    let id: String
    let label: String
}

struct QuotioCLIUsageWindow: Decodable, Sendable {
    struct Quota: Decodable, Sendable {
        let state: String
        let remainingPercent: Double?
        let amount: Double?
        let unit: String?
    }

    struct Amounts: Decodable, Sendable {
        let remaining: Double
        let limit: Double?
        let unit: String
    }

    struct Consumption: Decodable, Sendable {
        let used: Double
        let unit: String
    }

    let label: String
    let metricId: String?
    let quota: Quota
    let amounts: Amounts?
    let consumption: Consumption?
    let resetsAt: Date?
    let resetDescription: String?
    let fetchedAt: Date
    let note: String?
}

struct QuotioCLIUsageFailure: Decodable, Sendable {
    let provider: String
    let accountRef: QuotioCLIAccountReference?
    let code: String
}

struct QuotioCLISubscription: Decodable, Sendable {
    struct Tier: Decodable, Sendable {
        let id: String?
        let name: String?
        let description: String?
    }

    let currentTier: Tier?
    let paidTier: Tier?
}

struct QuotioCLIAccountList: Decodable, Sendable {
    let schemaVersion: Int
    let accounts: [QuotioCLIAccount]
}

struct QuotioCLIAccount: Decodable, Sendable {
    let id: String
    let provider: String
    let label: String
    let origin: String
    let enabled: Bool
    let sourceKind: String?
}

struct QuotioCLIOperation: Decodable, Sendable {
    let id: String
    let status: String
    let error: String?
}

struct QuotioCLIOAuthSession: Decodable, Sendable {
    let provider: String
    let workflow: String
    let userCode: String?
    let id: String
    let url: String
    let status: String
    let accountId: String?
    let errorCode: String?
}

enum QuotioCLIProviderMap {
    static func domain(_ id: String) -> QuotaProvider? {
        switch id {
        case "copilot": .copilot
        case "factory": .factoryDroid
        case "zai": .glm
        case "vertexai": .vertex
        case "devin-desktop": .devin
        default: QuotaProvider(rawValue: id)
        }
    }

    static func cli(_ provider: QuotaProvider) -> String? {
        switch provider {
        case .copilot: "copilot"
        case .factoryDroid: "factory"
        case .glm: "zai"
        case .vertex: "vertexai"
        case .devin: "devin-desktop"
        case .qwen, .iflow, .trae: nil
        default: provider.rawValue
        }
    }
}

enum QuotioCLIUsageMapper {
    static func snapshot(
        _ report: QuotioCLIUsageReport,
        mode: QuotaOperatingMode = .monitor
    ) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(lastUpdated: report.generatedAt)
        for usage in report.providers where mode == .monitor || usage.accountRef?.origin != "owned" {
            guard let provider = QuotioCLIProviderMap.domain(usage.provider) else { continue }
            let preferredKey = usage.accountRef?.label.nilIfEmpty
                ?? usage.account.label.nilIfEmpty
                ?? usage.accountRef?.id
                ?? usage.account.id
            let key = snapshot.quotas[provider]?[preferredKey] == nil
                ? preferredKey
                : usage.accountRef?.id ?? usage.account.id
            snapshot.quotas[provider, default: [:]][key] = quota(usage)
            if let reference = usage.accountRef {
                snapshot.accountAliases[provider, default: [:]][reference.id] = key
                if snapshot.accountAliases[provider]?[reference.label] == nil {
                    snapshot.accountAliases[provider, default: [:]][reference.label] = key
                }
                snapshot.accountIDs[provider, default: [:]][key] = reference.id
            }
            if let subscription = subscription(usage) {
                snapshot.subscriptions[provider, default: [:]][key] = subscription
            }
        }
        for failure in report.failures where mode == .monitor || failure.accountRef?.origin != "owned" {
            guard let provider = QuotioCLIProviderMap.domain(failure.provider) else { continue }
            let issue = QuotaRefreshIssue(kind: .failed, occurredAt: report.generatedAt)
            if let account = failure.accountRef {
                let key = snapshot.accountAliases[provider]?[account.id] ?? account.label
                snapshot.accountIssues[QuotaAccountID(provider: provider, accountKey: key)] = issue
            } else {
                snapshot.issues[provider] = issue
            }
        }
        return snapshot
    }

    private static func quota(_ usage: QuotioCLIProviderUsage) -> ProviderQuota {
        let updatedAt = usage.windows.map(\.fetchedAt)
            + [usage.codexProfile?.fetchedAt, usage.codexResetCredits?.fetchedAt, usage.resetCredits?.fetchedAt]
                .compactMap { $0 }
        return ProviderQuota(
            models: usage.windows.map { metric($0, provider: usage.provider) },
            lastUpdated: updatedAt.min() ?? .distantPast,
            planType: usage.account.plan,
            analytics: analytics(usage),
            accountDisplayName: usage.accountRef?.label.nilIfEmpty ?? usage.account.label
        )
    }

    private static func analytics(_ usage: QuotioCLIProviderUsage) -> QuotaAnalytics? {
        var analytics = usage.codexProfile.map(profileAnalytics) ?? QuotaAnalytics()
        let resetRows = resetCreditRows(usage)
        if !resetRows.isEmpty {
            analytics = analytics.merging(QuotaAnalytics(rows: resetRows))
        }
        return analytics.isEmpty ? nil : analytics
    }

    private static func profileAnalytics(_ profile: QuotioCLICodexProfile) -> QuotaAnalytics {
        let calendar = Calendar.current
        let buckets = Dictionary(uniqueKeysWithValues: profile.dailyUsage.map { ($0.date, $0.tokens) })
        let today = dayString(profile.fetchedAt, calendar: calendar)
        let yesterday = dayString(
            calendar.date(byAdding: .day, value: -1, to: profile.fetchedAt) ?? profile.fetchedAt,
            calendar: calendar
        )
        var rows = [
            dayRow(id: "today", title: "Today", tokens: buckets[today]),
            dayRow(id: "yesterday", title: "Yesterday", tokens: buckets[yesterday]),
            profile.latest30BucketsTokens > 0
                ? QuotaAnalyticsRow(
                    id: "last-30-days",
                    title: "Last 30 Days",
                    value: tokenLabel(profile.latest30BucketsTokens)
                )
                : noDataRow(id: "last-30-days", title: "Last 30 Days"),
        ]
        appendTokenRow(&rows, id: "codex-lifetime-tokens", title: "Lifetime Tokens", value: profile.lifetimeTokens)
        appendTokenRow(&rows, id: "codex-peak-daily", title: "Peak Daily", value: profile.peakDailyTokens)
        if let seconds = profile.longestRunningTurnSeconds, seconds > 0 {
            rows.append(QuotaAnalyticsRow(
                id: "codex-longest-task",
                title: "Longest Task",
                value: durationLabel(seconds)
            ))
        }
        appendDaysRow(&rows, id: "codex-current-streak", title: "Current Streak", value: profile.currentStreakDays)
        appendDaysRow(&rows, id: "codex-longest-streak", title: "Longest Streak", value: profile.longestStreakDays)
        return QuotaAnalytics(
            trend: profile.dailyUsage.map {
                QuotaAnalyticsPoint(
                    date: $0.date,
                    value: Double($0.tokens),
                    label: $0.date,
                    valueLabel: tokenLabel($0.tokens)
                )
            },
            rows: rows,
            note: "Account analytics from Codex"
        )
    }

    private static func resetCreditRows(_ usage: QuotioCLIProviderUsage) -> [QuotaAnalyticsRow] {
        guard let count = usage.codexResetCredits?.availableCount ?? usage.resetCredits?.availableCount else {
            return []
        }
        var rows = [QuotaAnalyticsRow(
            id: "codex-rate-limit-resets",
            title: "Rate Limit Resets",
            value: "\(count) available"
        )]
        if let inventory = usage.codexResetCredits {
            rows.append(contentsOf: inventory.credits.map { credit in
                QuotaAnalyticsRow(
                    id: "codex-rate-limit-reset-\(credit.id)",
                    title: expiryDateLabel(credit.expiresAt),
                    value: expiryRelativeLabel(credit.expiresAt, from: inventory.fetchedAt)
                )
            })
        }
        return rows
    }

    private static func dayRow(id: String, title: String, tokens: UInt64?) -> QuotaAnalyticsRow {
        guard let tokens, tokens > 0 else { return noDataRow(id: id, title: title) }
        return QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(tokens))
    }

    private static func noDataRow(id: String, title: String) -> QuotaAnalyticsRow {
        QuotaAnalyticsRow(id: id, title: title, value: "No data", isAvailable: false)
    }

    private static func appendTokenRow(
        _ rows: inout [QuotaAnalyticsRow],
        id: String,
        title: String,
        value: UInt64?
    ) {
        guard let value, value > 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(value)))
    }

    private static func appendDaysRow(
        _ rows: inout [QuotaAnalyticsRow],
        id: String,
        title: String,
        value: UInt64?
    ) {
        guard let value else { return }
        rows.append(QuotaAnalyticsRow(
            id: id,
            title: title,
            value: "\(integerLabel(value)) \(value == 1 ? "day" : "days")"
        ))
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func tokenLabel(_ value: UInt64) -> String {
        let number = Double(value)
        let text: String
        if number >= 1_000_000_000 {
            text = String(format: "%.1fB", number / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
        } else if number >= 1_000_000 {
            text = String(format: "%.1fM", number / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        } else if number >= 1_000 {
            text = String(format: "%.1fK", number / 1_000).replacingOccurrences(of: ".0K", with: "K")
        } else {
            text = integerLabel(value)
        }
        return "\(text) tokens"
    }

    private static func integerLabel(_ value: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private static func durationLabel(_ seconds: UInt64) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remaining = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remaining)s" }
        return "\(remaining)s"
    }

    private static func expiryDateLabel(_ date: Date?) -> String {
        guard let date else { return "No expiry" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM · HH:mm"
        return formatter.string(from: date)
    }

    private static func expiryRelativeLabel(_ expiry: Date?, from date: Date) -> String {
        guard let expiry else { return "" }
        let seconds = expiry.timeIntervalSince(date)
        if seconds <= 0 { return "expired" }
        let days = Int(ceil(seconds / 86_400))
        if days >= 1 { return "in \(days) \(days == 1 ? "day" : "days")" }
        let hours = Int(ceil(seconds / 3_600))
        if hours >= 1 { return "in \(hours) \(hours == 1 ? "hour" : "hours")" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        return "in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    private static func metric(_ window: QuotioCLIUsageWindow, provider: String) -> QuotaMetric {
        let percentage = switch window.quota.state {
        case "available", "exhausted":
            window.quota.remainingPercent.flatMap {
                $0.isFinite && (0...100).contains($0) ? $0 : nil
            } ?? -1.0
        default: -1.0
        }
        var presentation: QuotaMetricPresentation?
        switch window.quota.state {
        case "unlimited": presentation = .status(text: "Unlimited")
        case "disabled": presentation = .status(text: "Disabled")
        case "limit":
            if let amount = window.quota.amount {
                presentation = .status(text: "\(amount.formatted()) \(window.quota.unit ?? "") cap")
            }
        default: break
        }
        if presentation == nil,
           let amounts = window.amounts,
           let unit = QuotaMetricUnit(rawValue: amounts.unit.lowercased()) {
            if let limit = amounts.limit, limit > 0, percentage >= 0 {
                presentation = .progress(
                    used: max(0, limit - amounts.remaining),
                    limit: limit,
                    unit: unit
                )
            } else {
                presentation = .amount(value: amounts.remaining, unit: unit, semantics: .balance)
            }
        } else if presentation == nil,
                  let consumption = window.consumption,
                  let unit = QuotaMetricUnit(rawValue: consumption.unit.lowercased()) {
            presentation = .amount(value: consumption.used, unit: unit, semantics: .spent)
        }
        let reset = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return QuotaMetric(
            name: metricName(window, provider: provider),
            percentage: percentage,
            resetTime: reset,
            presentation: presentation,
            tooltip: [window.note, window.resetDescription]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    private static func metricName(_ window: QuotioCLIUsageWindow, provider: String) -> String {
        if provider == "codex" {
            let labels = [
                "Session": "codex-session",
                "Weekly": "codex-weekly",
                "Codex Spark Session": "codex-spark",
                "Codex Spark Weekly": "codex-spark-weekly",
            ]
            if let name = labels[window.label] { return name }
            let metrics = [
                "gpt-reserve-session": "codex-base-model-session",
                "gpt-reserve-weekly": "codex-base-model-limit",
            ]
            if let id = window.metricId, let name = metrics[id] { return name }
        }
        return window.metricId ?? window.label
    }

    private static func subscription(_ usage: QuotioCLIProviderUsage) -> QuotaSubscriptionInfo? {
        guard let subscription = usage.antigravitySubscription else { return nil }
        func tier(_ value: QuotioCLISubscription.Tier?) -> QuotaSubscriptionTier? {
            value.map {
                QuotaSubscriptionTier(
                    id: $0.id ?? "unknown",
                    name: $0.name ?? "Unknown",
                    description: $0.description ?? "",
                    privacyNotice: nil,
                    isDefault: nil,
                    upgradeSubscriptionUri: nil,
                    upgradeSubscriptionText: nil,
                    upgradeSubscriptionType: nil,
                    userDefinedCloudaicompanionProject: nil
                )
            }
        }
        return QuotaSubscriptionInfo(
            currentTier: tier(subscription.currentTier),
            allowedTiers: nil,
            cloudaicompanionProject: nil,
            gcpManaged: nil,
            upgradeSubscriptionUri: nil,
            paidTier: tier(subscription.paidTier)
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

func makeQuotioCLIDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid RFC3339 timestamp")
            )
        }
        return date
    }
    return decoder
}
