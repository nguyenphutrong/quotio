//
//  AdaptiveRefreshPlanner.swift
//  Quotio - Adaptive Quota Refresh Cadence
//
//  A fixed refresh cadence has to trade freshness against API pressure: a
//  10 minute cadence can miss a quota going 0% -> 100% while the user is
//  actively coding, while a 1 minute cadence keeps hammering provider APIs
//  overnight when nothing is happening (issue #172).
//
//  Adaptive refresh keeps the user's chosen cadence as the *fast* interval and
//  only backs off when no usage activity is observed, doubling the interval up
//  to a documented ceiling and snapping back to the fast cadence the moment
//  usage moves again.
//
//  Everything in this file is pure and timer-free so the cadence decision can
//  be unit tested without waiting on wall-clock time.
//

import Foundation

// MARK: - Bounds

/// Tunables for the adaptive backoff curve.
nonisolated struct AdaptiveRefreshBounds: Sendable, Equatable {
    /// Interval used while the user is active. This is the cadence picked in
    /// Settings, so adaptive mode never refreshes *more* often than the fixed
    /// mode would - it can only slow down.
    var fastInterval: TimeInterval

    /// How long the fast interval is held after the last observed activity
    /// before backoff starts.
    var idleGrace: TimeInterval

    /// Growth factor applied per idle refresh.
    var multiplier: Double

    /// Upper bound for the backed-off interval.
    var maxInterval: TimeInterval

    /// Ceiling for the whole backoff schedule, in seconds.
    static let defaultMaxInterval: TimeInterval = 1800  // 30 minutes

    /// Doubling backoff.
    static let defaultMultiplier: Double = 2

    init(
        fastInterval: TimeInterval,
        idleGrace: TimeInterval,
        multiplier: Double = AdaptiveRefreshBounds.defaultMultiplier,
        maxInterval: TimeInterval = AdaptiveRefreshBounds.defaultMaxInterval
    ) {
        self.fastInterval = fastInterval
        self.idleGrace = idleGrace
        self.multiplier = multiplier
        self.maxInterval = maxInterval
    }

    /// Bounds derived from the cadence the user picked in Settings.
    ///
    /// The fast interval is the chosen cadence, the grace window is two of
    /// those intervals (so a single quiet poll does not immediately slow things
    /// down), and the ceiling is 30 minutes - never shorter than the chosen
    /// cadence, so picking the 15 minute cadence still yields 15 -> 30 minutes.
    init(cadenceInterval: TimeInterval) {
        self.init(
            fastInterval: cadenceInterval,
            idleGrace: cadenceInterval * 2,
            multiplier: AdaptiveRefreshBounds.defaultMultiplier,
            maxInterval: max(cadenceInterval, AdaptiveRefreshBounds.defaultMaxInterval)
        )
    }

    /// Effective ceiling, clamped so it can never fall below the fast interval.
    var ceiling: TimeInterval {
        max(fastInterval, maxInterval)
    }
}

// MARK: - Interval Decision

/// Pure cadence decision for adaptive refresh.
nonisolated enum AdaptiveRefreshPlanner {

    /// Interval to wait before the next automatic refresh.
    ///
    /// - Parameters:
    ///   - current: Interval used for the refresh that just completed.
    ///   - timeSinceLastActivity: Seconds since usage was last observed to move.
    ///   - bounds: Backoff tunables derived from the user's cadence.
    /// - Returns: The fast interval while the user is (recently) active,
    ///   otherwise the current interval grown by `multiplier` and clamped to
    ///   `[fastInterval, ceiling]`.
    static func nextInterval(
        current: TimeInterval,
        timeSinceLastActivity: TimeInterval,
        bounds: AdaptiveRefreshBounds
    ) -> TimeInterval {
        let fast = max(0, bounds.fastInterval)
        let ceiling = max(fast, bounds.maxInterval)

        // Active (or only briefly quiet): stay at the user's cadence.
        guard timeSinceLastActivity >= bounds.idleGrace else { return fast }

        let grown = max(current, fast) * max(1, bounds.multiplier)
        return min(ceiling, max(fast, grown))
    }
}

// MARK: - Refresh Outcome

/// What one automatic quota refresh actually proved about user activity.
///
/// This is a *typed* result rather than something inferred from the quota
/// values, because the three states below are indistinguishable by value: a
/// batch refresh that returned early (another refresh already owns those
/// providers), a provider round-trip that failed (the coordinator keeps the
/// previous snapshot), and a mode with no local quota source all leave
/// `providerQuotas` looking exactly like "usage did not change". Treating any
/// of them as idleness is what makes the cadence back off - and stay backed off
/// at 30 minutes - precisely when the app needs to retry (issue #172).
nonisolated enum QuotaRefreshOutcome: Sendable, Equatable {
    /// A refresh ran to completion and produced a usable quota snapshot.
    /// This is the only outcome that is evidence about user activity.
    case sample

    /// No refresh ran: it was coalesced against an in-flight refresh, it was
    /// not due yet, or the active mode has no local quota source. Says nothing
    /// either way, so the cadence and the comparison baseline are left alone.
    case skipped

    /// A refresh ran but produced no usable data (transport/auth failure, or a
    /// provider-level issue reported by the Monitor coordinator). Not evidence
    /// of idleness: the cadence recovers to the user's interval so the app
    /// retries promptly instead of sitting on a backed-off delay.
    case failed
}

// MARK: - Activity Signal

/// Snapshot of the usage numbers Quotio already fetches for every account.
///
/// Comparing two consecutive snapshots is the activity signal for adaptive
/// refresh: if any account's consumption moved between polls, the user is
/// working. Timestamps are deliberately excluded so an unchanged quota that was
/// merely re-fetched does not look like activity.
nonisolated struct QuotaUsageSignature: Sendable, Equatable {
    /// `provider|account|model` -> consumption value.
    let entries: [String: Double]

    static let empty = QuotaUsageSignature(entries: [:])

    init(entries: [String: Double]) {
        self.entries = entries
    }

    /// Build a signature from the view model's quota map.
    init(quotas: [AIProvider: [String: ProviderQuotaData]]) {
        var entries: [String: Double] = [:]
        for (provider, accounts) in quotas {
            for (accountKey, data) in accounts {
                for model in data.models {
                    let key = "\(provider.rawValue)|\(accountKey)|\(model.name)"
                    entries[key] = Self.consumption(of: model)
                }
            }
        }
        self.entries = entries
    }

    /// The number that moves when the user spends quota on one row.
    ///
    /// The typed `QuotaMetricPresentation` wins over the legacy `Int` fields
    /// because several providers only populate the typed value:
    ///
    /// - `.amount` rows (Amp / OpenRouter balances, Factory Droid, Devin) are
    ///   built with `percentage: -1` and no `used`, so reading the legacy
    ///   fields collapsed every one of them to the constant `usedPercentage`
    ///   `100 - (-1) == 101` and their real consumption was invisible.
    ///   The value is used as-is: a `.balance` falls and a `.spent` rises, and
    ///   the signature only tests for inequality, so either direction reads as
    ///   activity.
    /// - `.progress` rows carry Double-valued `used`/`limit` (dollars for Amp,
    ///   OpenRouter and GLM) that the optional legacy `Int` does not mirror.
    ///
    /// `.status` rows are textual state rather than consumption, so they keep
    /// the legacy path and contribute no activity signal of their own.
    static func consumption(of model: ModelQuota) -> Double {
        switch model.presentation {
        case .progress(let used, _, _):
            return used
        case .amount(let value, _, _):
            return value
        case .status, .none:
            // `used` is an absolute counter where providers expose it;
            // otherwise fall back to the consumed percentage.
            return model.used.map(Double.init) ?? model.usedPercentage
        }
    }

    var isEmpty: Bool { entries.isEmpty }
}

// MARK: - Tracker

/// Timer-free state machine that turns a stream of quota snapshots into the
/// interval the refresh loop should sleep for.
///
/// The owning view model drives it: it feeds every completed refresh into
/// `observe(...)` and asks for `interval` before the next sleep.
nonisolated struct AdaptiveRefreshTracker: Sendable {

    /// Interval to use for the next automatic refresh.
    private(set) var interval: TimeInterval

    /// When usage was last observed to change.
    private(set) var lastActivityAt: Date

    /// Last observed usage snapshot, `nil` until the first observation.
    private var signature: QuotaUsageSignature?

    init(bounds: AdaptiveRefreshBounds, now: Date = Date()) {
        self.interval = max(0, bounds.fastInterval)
        self.lastActivityAt = now
        self.signature = nil
    }

    /// Snap back to the fast cadence, e.g. after the cadence setting changes or
    /// the refresh loop is restarted.
    mutating func reset(bounds: AdaptiveRefreshBounds, now: Date = Date()) {
        interval = max(0, bounds.fastInterval)
        lastActivityAt = now
        signature = nil
    }

    /// Feed the result of one automatic refresh into the tracker.
    ///
    /// Only `.sample` is treated as evidence about the user. A `.skipped` poll
    /// changes nothing at all, and a `.failed` poll recovers the cadence to the
    /// user's interval instead of backing off further - in both cases the
    /// comparison baseline is left untouched, so the next real sample is
    /// compared against the last real sample rather than against data that was
    /// never refreshed (issue #172).
    ///
    /// - Returns: `true` when usage moved since the previous *sample*.
    @discardableResult
    mutating func observe(
        outcome: QuotaRefreshOutcome,
        signature newSignature: QuotaUsageSignature,
        at now: Date,
        bounds: AdaptiveRefreshBounds
    ) -> Bool {
        switch outcome {
        case .skipped:
            // Nothing was measured, so nothing is known.
            return false
        case .failed:
            // A failure is not idleness. Retry at the user's cadence.
            interval = max(0, bounds.fastInterval)
            return false
        case .sample:
            break
        }

        defer { signature = newSignature }

        // First observation only seeds the baseline; there is nothing to
        // compare against yet, so stay at the fast cadence.
        guard let previous = signature else {
            lastActivityAt = now
            interval = max(0, bounds.fastInterval)
            return true
        }

        let didChange = previous != newSignature
        if didChange {
            lastActivityAt = now
        }

        interval = AdaptiveRefreshPlanner.nextInterval(
            current: interval,
            timeSinceLastActivity: now.timeIntervalSince(lastActivityAt),
            bounds: bounds
        )
        return didChange
    }

    /// Convenience overload for the view model's quota map.
    ///
    /// The signature is only built for `.sample`; the other outcomes ignore it,
    /// and building one from a map that was never refreshed would be misleading.
    @discardableResult
    mutating func observe(
        outcome: QuotaRefreshOutcome,
        quotas: [AIProvider: [String: ProviderQuotaData]],
        at now: Date = Date(),
        bounds: AdaptiveRefreshBounds
    ) -> Bool {
        let newSignature = outcome == .sample ? QuotaUsageSignature(quotas: quotas) : .empty
        return observe(outcome: outcome, signature: newSignature, at: now, bounds: bounds)
    }

    /// Last usage snapshot the tracker compared against, for tests and
    /// diagnostics. `nil` until the first `.sample` observation.
    var observedSignature: QuotaUsageSignature? { signature }
}
