import Foundation

/// The refresh cadence of a quota window, when the metric states one.
///
/// Display names are ambiguous and must never be the source: Claude's
/// `five-hour-session`, Codex's variable-length `codex-session` and Z.ai's
/// `zai-session` all render as "Session". Only the raw metric identity says
/// what the window actually is, and only some identities say it at all —
/// Codex classifies windows of up to 24 hours as a session, so there is no
/// correct fixed caption for it.
///
/// The rule is deliberately narrow: the duration is read from an explicit
/// period stated in the identity itself. Anything else returns `nil` and the
/// caption is omitted, which is the honest outcome — a wrong duration is worse
/// than none.
nonisolated enum QuotaMetricWindow: Equatable {
    case hours(Int)
    case days(Int)

    static func forMetric(named rawName: String) -> QuotaMetricWindow? {
        let name = rawName.lowercased()
        // Calendar months vary in length, so "monthly" states a period without
        // stating a duration; it is deliberately absent here.
        if name.contains("five-hour") { return .hours(5) }
        if name.contains("seven-day") { return .days(7) }
        if name.contains("weekly") { return .days(7) }
        if name.contains("daily") { return .hours(24) }
        return nil
    }

    /// Short caption such as "5h window" / "7d window".
    var caption: String {
        switch self {
        case .hours(let count):
            return String(format: "quota.window.hours".localizedStatic(), count)
        case .days(let count):
            return String(format: "quota.window.days".localizedStatic(), count)
        }
    }

    static func caption(forMetricNamed rawName: String) -> String? {
        forMetric(named: rawName)?.caption
    }
}
