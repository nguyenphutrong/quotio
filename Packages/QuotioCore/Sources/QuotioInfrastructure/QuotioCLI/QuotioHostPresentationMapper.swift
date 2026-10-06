import Foundation
import QuotioApplication
import QuotioDomain
import QuotioHostClient

struct QuotioHostPresentationMapper {
    let bundle: Bundle
    let locale: Locale

    private func localized(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    static func resolvedSnapshot(
        _ host: QuotioHostSnapshot,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> QuotaSnapshot {
        let mapper = Self(bundle: bundle, locale: locale)
        var snapshot = QuotaSnapshot(hostID: host.host.id, canRefresh: host.host.capabilities["refresh"]?.available == true, canManageSettings: host.host.capabilities["settings_write"]?.available == true, lastUpdated: host.generatedAt)
        snapshot.hostRevision = host.revision
        snapshot.historyAvailability = QuotioHistoryMapper.availability(host.host, connected: true)
        for (id, issue) in host.providerIssues ?? [:] {
            guard let provider = QuotaProvider(rawValue: id) else { continue }
            snapshot.issues[provider] = QuotaRefreshIssue(kind: .failed, occurredAt: host.generatedAt,
                reason: QuotaRefreshFailureReason(rawValue: issue.code), recoveryAction: recoveryAction(issue.action))
        }
        for account in host.accounts {
            guard let provider = QuotaProvider(rawValue: account.providerId) else { continue }
            let key = account.id
            let usage = host.usage.first(where: { $0.accountId == key })
            let connection: ConnectionState = switch account.state {
            case "ready": .connected
            case "needs_authorization": .permissionRequired
            case "needs_login": .reauthenticationRequired
            case "disabled": .disabled
            default: .notConnected
            }
            let quotaState: QuotaRefreshState = switch usage?.freshness {
            case "fresh": .fresh
            case "stale": .stale
            case "unavailable": .failed(usage?.issue.flatMap { QuotaRefreshFailureReason(rawValue: $0.code) })
            default: .notLoaded
            }
            snapshot.accountStates[QuotaAccountID(provider: provider, accountKey: key)] = .init(connection: connection, quota: quotaState)
            snapshot.accountAliases[provider, default: [:]][key] = key
            for source in account.sources {
                if source.selected { snapshot.accountIDs[provider, default: [:]][key] = source.id }
                if let issue = source.issue {
                    snapshot.sourceIssues[provider, default: [:]][source.id] = QuotaRefreshIssue(
                        kind: source.state == "ready" ? .partial : .failed, occurredAt: host.generatedAt,
                        reason: QuotaRefreshFailureReason(rawValue: issue.code), recoveryAction: recoveryAction(issue.action)
                    )
                }
            }
            guard account.enabled, let usage else { continue }
            if let issue = usage.issue {
                snapshot.accountIssues[QuotaAccountID(provider: provider, accountKey: key)] = QuotaRefreshIssue(
                    kind: usage.freshness == "fresh" ? .partial : .failed, occurredAt: host.generatedAt,
                    reason: QuotaRefreshFailureReason(rawValue: issue.code), recoveryAction: recoveryAction(issue.action)
                )
            }
            guard usage.freshness == "fresh" || usage.freshness == "stale" else { continue }
            let quota = mapper.quota(usage, name: account.displayName)
            snapshot.quotas[provider, default: [:]][key] = quota
            if let subscription = mapper.subscription(usage) {
                snapshot.subscriptions[provider, default: [:]][key] = subscription
            }
        }
        for (previous, current) in host.accountRedirects ?? [:] {
            guard let account = host.accounts.first(where: { $0.id == current }),
                  let provider = QuotaProvider(rawValue: account.providerId) else { continue }
            snapshot.accountAliases[provider, default: [:]][previous] = current
        }
        return snapshot
    }

    private static func recoveryAction(_ action: QuotioHostSnapshot.Action?) -> QuotaRecoveryAction? {
        guard let action, action.available else { return nil }
        return switch action.kind {
        case "sign_in": .signIn
        case "refresh_in_source_app": .refreshInSourceApp
        case "authorize": .authorize
        case "retry": .retry
        default: nil
        }
    }

    private func quota(_ usage: QuotioHostSnapshot.Usage, name: String) -> ProviderQuota {
        ProviderQuota(
            models: usage.metrics.map(metric),
            lastUpdated: usage.fetchedAt ?? .distantPast,
            planType: usage.plan,
            analytics: analytics(usage),
            accountDisplayName: name,
            summary: usage.summary.map { value in
                QuotaSummary(
                    sessionOnly: .init(lowest: value.sessionOnly.lowest, average: value.sessionOnly.average),
                    combined: .init(lowest: value.combined.lowest, average: value.combined.average),
                    pair: value.pair.map { .init(displayName: $0.displayName, remainingPercent: $0.remainingPercent) }
                )
            }
        )
    }

    private func analytics(_ usage: QuotioHostSnapshot.Usage) -> QuotaAnalytics? {
        var analytics = usage.codexProfile.map(profileAnalytics) ?? QuotaAnalytics()
        let resetRows = resetCreditRows(usage)
        if !resetRows.isEmpty {
            analytics = analytics.merging(QuotaAnalytics(rows: resetRows))
        }
        return analytics.isEmpty ? nil : analytics
    }

    private func profileAnalytics(_ profile: QuotioHostCodexProfile) -> QuotaAnalytics {
        let calendar = Calendar.current
        let buckets = Dictionary(uniqueKeysWithValues: profile.dailyUsage.map { ($0.date, $0.tokens) })
        let today = dayString(profile.fetchedAt, calendar: calendar)
        let yesterday = dayString(
            calendar.date(byAdding: .day, value: -1, to: profile.fetchedAt) ?? profile.fetchedAt,
            calendar: calendar
        )
        var rows = [
            dayRow(id: "today", title: localized("quota.metric.today", "Today"), tokens: buckets[today]),
            dayRow(id: "yesterday", title: localized("quota.analytics.yesterday", "Yesterday"), tokens: buckets[yesterday]),
            QuotaAnalyticsRow(
                id: "last-30-days",
                title: localized("quota.analytics.last30Days", "Latest 30 recorded days"),
                value: tokenLabel(profile.latest30BucketsTokens)
            ),
        ]
        appendTokenRow(&rows, id: "codex-lifetime-tokens", title: localized("quota.analytics.lifetimeTokens", "Lifetime Tokens"), value: profile.lifetimeTokens)
        appendTokenRow(&rows, id: "codex-peak-daily", title: localized("quota.analytics.peakDaily", "Peak Daily"), value: profile.peakDailyTokens)
        if let seconds = profile.longestRunningTurnSeconds {
            rows.append(QuotaAnalyticsRow(
                id: "codex-longest-task",
                title: localized("quota.analytics.longestTask", "Longest Task"),
                value: durationLabel(seconds)
            ))
        }
        appendDaysRow(&rows, id: "codex-current-streak", title: localized("quota.analytics.currentStreak", "Current Streak"), value: profile.currentStreakDays)
        appendDaysRow(&rows, id: "codex-longest-streak", title: localized("quota.analytics.longestStreak", "Longest Streak"), value: profile.longestStreakDays)
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
            note: localized("quota.analytics.codexNote", "Account analytics from Codex")
        )
    }

    private func resetCreditRows(_ usage: QuotioHostSnapshot.Usage) -> [QuotaAnalyticsRow] {
        guard let count = usage.codexResetCredits?.availableCount ?? usage.resetCredits?.availableCount else {
            return []
        }
        var rows = [QuotaAnalyticsRow(
            id: "codex-rate-limit-resets",
            title: localized("quota.analytics.rateLimitResets", "Rate Limit Resets"),
            value: String(format: localized("quota.analytics.available", "%@ available"), integerLabel(count))
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

    private func dayRow(id: String, title: String, tokens: UInt64?) -> QuotaAnalyticsRow {
        guard let tokens else { return noDataRow(id: id, title: title) }
        return QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(tokens))
    }

    private func noDataRow(id: String, title: String) -> QuotaAnalyticsRow {
        QuotaAnalyticsRow(id: id, title: title, value: localized("quota.analytics.noData", "No data"), isAvailable: false)
    }

    private func appendTokenRow(
        _ rows: inout [QuotaAnalyticsRow],
        id: String,
        title: String,
        value: UInt64?
    ) {
        guard let value else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(value)))
    }

    private func appendDaysRow(
        _ rows: inout [QuotaAnalyticsRow],
        id: String,
        title: String,
        value: UInt64?
    ) {
        guard let value else { return }
        rows.append(QuotaAnalyticsRow(
            id: id,
            title: title,
            value: String(format: localized(value == 1 ? "quota.analytics.day" : "quota.analytics.days", value == 1 ? "%@ day" : "%@ days"), integerLabel(value))
        ))
    }

    private func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func tokenLabel(_ value: UInt64) -> String {
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
        return String(format: localized("quota.analytics.tokens", "%@ tokens"), text)
    }

    private func integerLabel(_ value: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func durationLabel(_ seconds: UInt64) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remaining = seconds % 60
        if hours > 0 { return String(format: localized("quota.analytics.hoursMinutes", "%@h %@m"), integerLabel(hours), integerLabel(minutes)) }
        if minutes > 0 { return String(format: localized("quota.analytics.minutesSeconds", "%@m %@s"), integerLabel(minutes), integerLabel(remaining)) }
        return String(format: localized("quota.analytics.seconds", "%@s"), integerLabel(remaining))
    }

    private func expiryDateLabel(_ date: Date?) -> String {
        guard let date else { return localized("quota.analytics.noExpiry", "No expiry") }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return formatter.string(from: date)
    }

    private func expiryRelativeLabel(_ expiry: Date?, from date: Date) -> String {
        guard let expiry else { return "" }
        let seconds = expiry.timeIntervalSince(date)
        if seconds <= 0 { return localized("quota.analytics.expired", "expired") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: expiry, relativeTo: date)
    }

    private func metric(_ window: QuotioHostSnapshot.Metric) -> QuotaMetric {
        let percentage = switch window.quota.state {
        case "available", "exhausted":
            window.quota.remainingPercent.flatMap {
                $0.isFinite && (0...100).contains($0) ? $0 : nil
            } ?? -1.0
        default: -1.0
        }
        var presentation: QuotaMetricPresentation?
        switch window.quota.state {
        case "unlimited": presentation = .status(text: localized("quota.metric.unlimited", "Unlimited"))
        case "disabled": presentation = .status(text: localized("grok.status.disabled", "Disabled"))
        case "limit":
            if let amount = window.quota.amount {
                presentation = .status(text: String(format: localized("grok.status.cap", "%@ cap"), "\(amount.formatted()) \(window.quota.unit ?? "")"))
            }
        case "available", "exhausted", "unknown": break
        default: presentation = .status(text: localized("quota.metric.unsupported", "Unsupported"))
        }
        if presentation == nil,
           let amounts = window.amounts,
           let unit = QuotaMetricUnit(rawValue: amounts.unit) {
            if let limit = amounts.limit, limit > 0, percentage >= 0,
               let consumption = window.consumption, QuotaMetricUnit(rawValue: consumption.unit) == unit {
                presentation = .progress(
                    used: consumption.used,
                    limit: limit,
                    unit: unit
                )
            } else {
                presentation = .amount(value: amounts.remaining, unit: unit, semantics: .balance)
            }
        } else if presentation == nil,
                  let consumption = window.consumption,
                  let unit = QuotaMetricUnit(rawValue: consumption.unit) {
            presentation = .amount(value: consumption.used, unit: unit, semantics: .spent)
        }
        let reset = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return QuotaMetric(
            name: window.displayName,
            id: window.id,
            percentage: percentage,
            resetTime: reset,
            presentation: presentation,
            tooltip: [window.note, window.resetDescription]
                .compactMap { $0 }
                .joined(separator: "\n"),
            group: window.group
        )
    }

    private func subscription(_ usage: QuotioHostSnapshot.Usage) -> QuotaSubscriptionInfo? {
        guard let subscription = usage.antigravitySubscription else { return nil }
        func tier(_ value: QuotioHostSubscription.Tier?) -> QuotaSubscriptionTier? {
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
