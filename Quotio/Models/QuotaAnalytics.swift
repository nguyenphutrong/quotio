import QuotioDomain

typealias QuotaAnalytics = QuotioDomain.QuotaAnalytics
typealias QuotaAnalyticsPoint = QuotioDomain.QuotaAnalyticsPoint
typealias QuotaAnalyticsRow = QuotioDomain.QuotaAnalyticsRow

nonisolated extension QuotaAnalyticsRow {
    static func noData(id: String, title: String) -> QuotaAnalyticsRow {
        QuotaAnalyticsRow(id: id, title: title, value: "No data", isAvailable: false)
    }
}
