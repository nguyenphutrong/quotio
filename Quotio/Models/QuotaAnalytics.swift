import Foundation

nonisolated struct QuotaAnalytics: Codable, Equatable, Sendable {
    var trend: [QuotaAnalyticsPoint]
    var rows: [QuotaAnalyticsRow]
    var note: String?

    init(
        trend: [QuotaAnalyticsPoint] = [],
        rows: [QuotaAnalyticsRow] = [],
        note: String? = nil
    ) {
        self.trend = trend
        self.rows = rows
        self.note = note
    }

    var isEmpty: Bool {
        trend.isEmpty && rows.isEmpty && (note?.isEmpty ?? true)
    }

    func merging(_ other: QuotaAnalytics?) -> QuotaAnalytics {
        guard let other, !other.isEmpty else { return self }
        var mergedRows = rows
        var seen = Set(rows.map(\.id))
        for row in other.rows where seen.insert(row.id).inserted {
            mergedRows.append(row)
        }
        return QuotaAnalytics(
            trend: other.trend.isEmpty ? trend : other.trend,
            rows: mergedRows,
            note: other.note ?? note
        )
    }
}

nonisolated struct QuotaAnalyticsPoint: Codable, Equatable, Identifiable, Sendable {
    var id: String { date }
    var date: String
    var value: Double
    var label: String
    var valueLabel: String

    init(date: String, value: Double, label: String, valueLabel: String) {
        self.date = date
        self.value = value
        self.label = label
        self.valueLabel = valueLabel
    }
}

nonisolated struct QuotaAnalyticsRow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var value: String
    var isAvailable: Bool

    init(id: String, title: String, value: String, isAvailable: Bool = true) {
        self.id = id
        self.title = title
        self.value = value
        self.isAvailable = isAvailable
    }

    static func noData(id: String, title: String) -> QuotaAnalyticsRow {
        QuotaAnalyticsRow(id: id, title: title, value: "No data", isAvailable: false)
    }
}
