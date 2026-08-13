//
//  QuotaBucketKind.swift
//  Quotio
//
//  Explicit, fetcher-declared classification of a quota bucket.
//

import Foundation

// MARK: - Quota Window

/// The recurring window a quota bucket refills on.
///
/// This is set by the fetcher that produced the bucket, from evidence in the
/// provider payload (a declared window length, a period type, an explicit
/// limit type). It is deliberately never derived from `ModelQuota.name`:
/// those strings are display/identifier slugs — several of them are built at
/// runtime from provider fields (`codex-<metered feature>`,
/// `antigravity-<group>-<period>`, `warp-bonus-<n>`) — so they carry no
/// reliable domain meaning.
///
/// A bucket whose window the provider does not state keeps `nil`. Unknown
/// stays unknown; it is never guessed.
nonisolated enum QuotaWindow: String, Codable, Sendable, CaseIterable, Hashable {
    /// Short rolling window (Codex/Claude five-hour, ClinePass five-hour, ...).
    case session
    case daily
    case weekly
    case monthly
}

// MARK: - Quota Billing

/// How a quota bucket is paid for.
///
/// Like `QuotaWindow`, this is declared by the producing fetcher and never
/// inferred from the bucket name. `nil` means the provider payload gives no
/// billing signal, and is treated as "not paid overage" so an unclassified
/// bucket keeps counting toward subscription totals.
nonisolated enum QuotaBilling: String, Codable, Sendable, Hashable {
    /// Included in the plan.
    case subscription
    /// Billed on top of the plan (extra usage credits, on-demand spend).
    case paidOverage
}

// MARK: - Usage Calculation

/// Pure quota math shared by the menu bar, the dashboard and the quota screen.
///
/// Kept free of `MenuBarSettingsManager` so the calculation can be exercised
/// without mutating (and persisting to) the app's real preferences.
nonisolated enum QuotaUsageCalculator {
    /// Aggregate a set of remaining percentages, ignoring the `-1` "unknown"
    /// sentinel that fetchers use for status/balance rows.
    /// Returns `-1` when nothing is known.
    static func aggregate(_ percentages: [Double], mode: ModelAggregationMode) -> Double {
        let valid = percentages.filter { $0 >= 0 }
        guard !valid.isEmpty else { return -1 }

        switch mode {
        case .lowest:
            return valid.min() ?? -1
        case .average:
            return valid.reduce(0, +) / Double(valid.count)
        }
    }

    /// Split buckets into subscription and paid-overage groups using the
    /// billing kind each fetcher declared, then combine per `totalMode`.
    static func totalUsagePercent(
        models: [ModelQuota],
        totalMode: TotalUsageMode,
        aggregation: ModelAggregationMode
    ) -> Double {
        var sessionPercentages: [Double] = []
        var extraPercentages: [Double] = []

        for model in models {
            if model.billing == .paidOverage {
                extraPercentages.append(model.percentage)
            } else {
                sessionPercentages.append(model.percentage)
            }
        }

        let sessionRemaining = aggregate(sessionPercentages, mode: aggregation)
        let extraRemaining = aggregate(extraPercentages, mode: aggregation)
        let hasExtraModels = !extraPercentages.isEmpty

        switch totalMode {
        case .sessionOnly:
            if sessionRemaining >= 0 {
                return sessionRemaining
            }
            if hasExtraModels {
                return extraRemaining
            }
            return -1

        case .combined:
            let session = sessionRemaining >= 0 ? sessionRemaining : -1
            let extra = extraRemaining >= 0 ? extraRemaining : -1

            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
}
