import Foundation
import QuotioDomain

/// Finds the pace a menu bar value is colored by when the menu bar colors by pace.
public enum MenuBarPaceResolver {
    /// The worst pace among the limits that have a known window, or nil when none has one.
    /// The single menu bar value summarizes all of an account's limits, so any limit
    /// spent too fast should show.
    public static func worstStatus(of metrics: [QuotaMetric], now: Date = Date()) -> QuotaPace.Status? {
        metrics.compactMap { $0.pace(now: now)?.status }.max(by: { severity($0) < severity($1) })
    }

    /// The pace of the limit behind one value of a stacked pair. The host sends the pair
    /// as a name and the lowest remaining percentage of its group, so the limit is found
    /// by that percentage, preferring limits whose name matches the pair label.
    public static func status(forPairValue remaining: Double, label: String, in metrics: [QuotaMetric], now: Date = Date()) -> QuotaPace.Status? {
        guard remaining >= 0 else { return nil }
        let sameValue = metrics.filter { $0.percentage == remaining }
        let named = sameValue.filter { matches($0.name, label: label) }
        return worstStatus(of: named.isEmpty ? sameValue : named, now: now)
    }

    private static func matches(_ name: String, label: String) -> Bool {
        let name = name.lowercased(), label = label.lowercased()
        return name == label || name.hasSuffix(" \(label)")
    }

    private static func severity(_ status: QuotaPace.Status) -> Int {
        switch status {
        case .onPace: 0
        case .behind: 1
        case .exhausted: 2
        }
    }
}
