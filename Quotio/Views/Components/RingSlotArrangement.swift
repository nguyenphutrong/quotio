import Foundation

/// Where a metric belongs in a ring row, independent of how many metrics a
/// provider happens to report.
///
/// Positional layout made a slot mean different things for different accounts:
/// an account without a Session window put Weekly in the first column, so two
/// cards stacked vertically compared unlike things side by side. Roles pin the
/// recurring windows to fixed columns and leave a placeholder when one is
/// absent.
nonisolated enum RingSlotRole: Int, CaseIterable {
    case session = 0
    case weekly = 1

    static func role(forMetricNamed rawName: String) -> RingSlotRole? {
        let name = rawName.lowercased()
        // "weekly" is checked first: `seven-day-weekly` would otherwise match
        // nothing, while a hypothetical `weekly-session` should read as weekly.
        if name.contains("weekly") { return .weekly }
        if name.contains("session") || name.contains("five-hour") { return .session }
        return nil
    }
}

/// Shared ring-row geometry for the dashboard and the menu popover.
///
/// Both surfaces must agree: a metric that sits in the second column on the
/// dashboard has to sit in the second column of the menu too, or the two views
/// contradict each other for the same account.
nonisolated enum RingSlotArrangement {
    /// The widest a single ring row gets before it wraps.
    static let maxColumns = 4

    /// The narrowest a row gets, so an account missing a metric still lines up
    /// column-for-column with accounts that have all three.
    static let minColumns = 3

    /// Places items into stable semantic columns, `nil` where a role has no
    /// metric.
    ///
    /// Semantic columns are only reserved when the provider actually uses that
    /// vocabulary; a provider reporting Chat/Completions/Premium lays out
    /// positionally rather than growing two empty columns.
    static func arrange<T>(_ items: [T], rawName: (T) -> String) -> [T?] {
        var roleSlots: [RingSlotRole: T] = [:]
        var rest: [T] = []

        for item in items {
            if let role = RingSlotRole.role(forMetricNamed: rawName(item)), roleSlots[role] == nil {
                roleSlots[role] = item
            } else {
                rest.append(item)
            }
        }

        guard !roleSlots.isEmpty else { return items.map { Optional($0) } }

        var arranged: [T?] = RingSlotRole.allCases.map { roleSlots[$0] }
        // Trim trailing placeholders so a provider with only a Session window
        // does not carry an empty Weekly column forever. A leading gap is kept:
        // that is what holds Weekly in its own column.
        if rest.isEmpty {
            while arranged.count > 1, let last = arranged.last, last == nil {
                arranged.removeLast()
            }
        }
        arranged.append(contentsOf: rest.map { Optional($0) })
        return arranged
    }

    /// Splits arranged slots into rows that wrap rather than truncate.
    ///
    /// The grid renders a fixed number of columns, so without wrapping a
    /// provider reporting more than `maxColumns` metrics (Kiro appends both a
    /// bonus and a base metric per breakdown entry) would simply lose the
    /// extras — the previous `LazyVGrid` wrapped them.
    static func rows<T>(_ arranged: [T?]) -> [[T?]] {
        guard !arranged.isEmpty else { return [] }
        return stride(from: 0, to: arranged.count, by: maxColumns).map { start in
            Array(arranged[start..<min(start + maxColumns, arranged.count)])
        }
    }

    /// Column count for a row, padded to `minColumns` so rows align.
    static func columnCount<T>(for row: [T?]) -> Int {
        min(max(row.count, minColumns), maxColumns)
    }
}
