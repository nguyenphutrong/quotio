//
//  MenuBarBucketSelection.swift
//  Quotio
//
//  Per-item choice of which quota bucket the menu bar value shows (issue #393).
//

import Foundation

// MARK: - Selection

/// What a single menu bar item shows.
///
/// Buckets are addressed either by the window their producing fetcher declared
/// (`QuotaWindow`) or by the exact `ModelQuota.name`, so a user can pin the
/// Factory Standard five-hour pool, the Antigravity Gemini session pool, or a
/// paid on-demand bucket rather than an aggregate.
nonisolated enum MenuBarBucketSelection: Codable, Hashable, Sendable {
    /// Existing behaviour: aggregate every bucket per the usage display settings.
    case auto
    /// Every bucket the fetcher declared as this window, aggregated per
    /// `ModelAggregationMode`.
    case window(QuotaWindow)
    /// One exact bucket, addressed by `ModelQuota.name`.
    case bucket(String)
}

// MARK: - Resolution

nonisolated enum MenuBarBucketResolver {
    /// The remaining percentage for `selection`, or `nil` when the selection is
    /// not available for this account — no bucket carries that window, the named
    /// bucket is gone, or the value is the `-1` unknown sentinel. Callers fall
    /// back to the aggregate total in that case.
    static func percent(
        models: [ModelQuota],
        selection: MenuBarBucketSelection,
        aggregation: ModelAggregationMode
    ) -> Double? {
        switch selection {
        case .auto:
            return nil

        case .window(let window):
            let matching = models.filter { $0.window == window }.map(\.percentage)
            let value = QuotaUsageCalculator.aggregate(matching, mode: aggregation)
            return value >= 0 ? value : nil

        case .bucket(let name):
            guard let model = models.first(where: { $0.name == name }), model.percentage >= 0 else {
                return nil
            }
            return model.percentage
        }
    }

    /// Selections offered for an account, in menu order: automatic, then each
    /// window at least one bucket declares, then every individual bucket that
    /// reports a percentage.
    ///
    /// Buckets with the `-1` unknown sentinel (status rows such as
    /// `grok-extra-usage`, currency balances such as `factory-extra-balance`) are
    /// omitted: the menu bar renders a percentage, which they do not have.
    static func options(for models: [ModelQuota]) -> [MenuBarBucketSelection] {
        var options: [MenuBarBucketSelection] = [.auto]

        for window in QuotaWindow.allCases where models.contains(where: { $0.window == window }) {
            options.append(.window(window))
        }

        var seen = Set<String>()
        for model in models where model.percentage >= 0 && seen.insert(model.name).inserted {
            options.append(.bucket(model.name))
        }

        return options
    }

    /// Whether a stored selection can still be honored for this account.
    static func isAvailable(
        _ selection: MenuBarBucketSelection,
        in models: [ModelQuota]
    ) -> Bool {
        switch selection {
        case .auto:
            return true
        case .window(let window):
            return models.contains { $0.window == window }
        case .bucket(let name):
            return models.contains { $0.name == name }
        }
    }
}

// MARK: - Labels

extension MenuBarBucketSelection {
    /// Localization key for the selection, or `nil` for `.bucket` — a specific
    /// bucket is labelled with `ModelQuota.displayName`.
    var localizationKey: String? {
        switch self {
        case .auto:
            return "settings.menubar.bucket.auto"
        case .window(let window):
            return window.localizationKey
        case .bucket:
            return nil
        }
    }
}

extension QuotaWindow {
    var localizationKey: String {
        switch self {
        case .session: return "quota.window.session"
        case .daily: return "quota.window.daily"
        case .weekly: return "quota.window.weekly"
        case .monthly: return "quota.window.monthly"
        }
    }
}

// MARK: - Quota Lookup

@MainActor
extension QuotaViewModel {
    /// Quota data for a menu bar item, tolerating the account-key variants the
    /// menu bar selection can hold (`.json` suffix, Codex filename keys).
    func menuBarQuotaData(for item: MenuBarQuotaItem) -> ProviderQuotaData? {
        guard let provider = item.aiProvider,
              let accountQuotas = providerQuotas[provider] else { return nil }

        if let quotaData = accountQuotas[item.accountKey] {
            return quotaData
        }

        let cleanKey = item.accountKey.hasSuffix(".json")
            ? String(item.accountKey.dropLast(".json".count))
            : item.accountKey
        if let quotaData = accountQuotas[cleanKey] {
            return quotaData
        }

        guard provider == .codex else { return nil }
        return accountQuotas[item.accountKey.codexFilenameKey]
    }
}
