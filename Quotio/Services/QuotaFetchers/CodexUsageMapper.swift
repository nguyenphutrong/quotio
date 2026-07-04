import Foundation

nonisolated struct CodexQuotaIdentity: Sendable {
    var planType: String?
}

nonisolated enum CodexUsageMapper {
    static func map(
        data: Data,
        identity: CodexQuotaIdentity = CodexQuotaIdentity(),
        updatedAt: Date = Date()
    ) throws -> ProviderQuotaData {
        let response = try JSONDecoder().decode(CodexUsageResponseV2.self, from: data)
        let rawJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        var models: [ModelQuota] = []
        if let primary = modelQuota(name: "codex-session", from: response.rateLimit?.primaryWindow) {
            models.append(primary)
        }
        if let secondary = modelQuota(name: "codex-weekly", from: response.rateLimit?.secondaryWindow) {
            models.append(secondary)
        }
        models.append(contentsOf: extraModels(from: response.additionalRateLimits))

        let planType = response.planType ?? identity.planType
        return ProviderQuotaData(
            models: models,
            lastUpdated: updatedAt,
            isForbidden: response.rateLimit?.limitReached ?? false,
            planType: planType,
            analytics: analytics(from: rawJSON)
        )
    }

    private static func modelQuota(name: String, from snapshot: CodexUsageResponseV2.WindowSnapshot?) -> ModelQuota? {
        guard let snapshot else { return nil }
        return ModelQuota(
            name: name,
            percentage: Double(100 - snapshot.usedPercent),
            resetTime: snapshot.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        )
    }

    private static func extraModels(from limits: [CodexUsageResponseV2.AdditionalRateLimit]?) -> [ModelQuota] {
        guard let limits, !limits.isEmpty else { return [] }
        var usedIDs = Set<String>()
        return limits.flatMap { limit in
            if isSpark(limit) {
                return sparkModels(from: limit, usedIDs: &usedIDs)
            }

            guard let snapshot = limit.rateLimit?.primaryWindow ?? limit.rateLimit?.secondaryWindow,
                  let id = modelID(for: limit),
                  usedIDs.insert(id).inserted
            else {
                return []
            }
            return [ModelQuota(
                name: id,
                percentage: Double(100 - snapshot.usedPercent),
                resetTime: snapshot.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            )]
        }
    }

    private static func sparkModels(
        from limit: CodexUsageResponseV2.AdditionalRateLimit,
        usedIDs: inout Set<String>
    ) -> [ModelQuota] {
        [
            (limit.rateLimit?.primaryWindow, sparkKind(for: limit.rateLimit?.primaryWindow, fallback: .fiveHour)),
            (limit.rateLimit?.secondaryWindow, sparkKind(for: limit.rateLimit?.secondaryWindow, fallback: .weekly))
        ].compactMap { snapshot, kind in
            guard let snapshot, usedIDs.insert(kind.id).inserted else { return nil }
            return ModelQuota(
                name: kind.id,
                percentage: Double(100 - snapshot.usedPercent),
                resetTime: snapshot.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            )
        }
    }

    private static func sparkKind(
        for snapshot: CodexUsageResponseV2.WindowSnapshot?,
        fallback: SparkWindowKind
    ) -> SparkWindowKind {
        guard let minutes = snapshot?.windowMinutes else { return fallback }
        if minutes <= 6 * 60 { return .fiveHour }
        if minutes >= 6 * 24 * 60 { return .weekly }
        return fallback
    }

    private static func modelID(for limit: CodexUsageResponseV2.AdditionalRateLimit) -> String? {
        guard let source = firstNonEmpty(limit.meteredFeature, limit.limitName) else { return nil }
        let slug = slug(source)
        return slug.isEmpty ? nil : "codex-\(slug)"
    }

    private static func isSpark(_ limit: CodexUsageResponseV2.AdditionalRateLimit) -> Bool {
        [limit.limitName, limit.meteredFeature]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func analytics(from json: [String: Any]?) -> QuotaAnalytics? {
        guard let json else { return nil }
        var rows: [QuotaAnalyticsRow] = []
        if let credits = creditsRemaining(from: json) {
            let creditCount = Int(max(0, credits.rounded(.down)))
            rows.append(QuotaAnalyticsRow(
                id: "codex-extra-usage",
                title: "Extra Usage",
                value: "\(formatDollars(Double(creditCount) * 0.04)) - \(creditCount) credits"
            ))
        }
        if let count = resetCreditsCount(from: json) {
            rows.append(QuotaAnalyticsRow(
                id: "codex-rate-limit-resets",
                title: "Rate Limit Resets",
                value: "\(count) available"
            ))
        }
        return rows.isEmpty ? nil : QuotaAnalytics(rows: rows)
    }

    private static func creditsRemaining(from json: [String: Any]) -> Double? {
        guard let credits = json["credits"] as? [String: Any] else { return nil }
        if let balance = doubleValue(credits["balance"]) {
            return max(0, balance)
        }
        if credits["has_credits"] as? Bool == false {
            return 0
        }
        return nil
    }

    private static func resetCreditsCount(from json: [String: Any]) -> Int? {
        guard let resets = json["rate_limit_reset_credits"] as? [String: Any],
              let count = doubleValue(resets["available_count"]),
              count >= 0
        else {
            return nil
        }
        return Int(count.rounded(.down))
    }

    private static func formatDollars(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "$%.1fK", value / 1000)
        }
        return String(format: "$%.2f", value)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value = trimmedNonEmpty(value) {
                return value
            }
        }
        return nil
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private enum SparkWindowKind {
        case fiveHour
        case weekly

        var id: String {
            switch self {
            case .fiveHour: "codex-spark"
            case .weekly: "codex-spark-weekly"
            }
        }
    }
}

nonisolated struct CodexUsageResponseV2: Decodable {
    var planType: String?
    var rateLimit: RateLimitDetails?
    var additionalRateLimits: [AdditionalRateLimit]?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
        if let decoded = try? container.decodeIfPresent([LossyAdditionalRateLimit].self, forKey: .additionalRateLimits) {
            additionalRateLimits = decoded.compactMap(\.value)
        }
    }

    struct RateLimitDetails: Decodable {
        var limitReached: Bool?
        var primaryWindow: WindowSnapshot?
        var secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitReached = try? container.decodeIfPresent(Bool.self, forKey: .limitReached)
            primaryWindow = try? container.decodeIfPresent(WindowSnapshot.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decodeIfPresent(WindowSnapshot.self, forKey: .secondaryWindow)
        }
    }

    struct WindowSnapshot: Decodable {
        var usedPercent: Int
        var resetAt: Int?
        var limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = (try Self.flexibleInt(container, forKey: .usedPercent)).clamped(to: 0...100)
            resetAt = try? Self.flexibleInt(container, forKey: .resetAt)
            limitWindowSeconds = try? Self.flexibleInt(container, forKey: .limitWindowSeconds)
        }

        var resetDate: Date? {
            guard let resetAt, resetAt > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(resetAt))
        }

        var windowMinutes: Int? {
            guard let limitWindowSeconds, limitWindowSeconds > 0 else { return nil }
            return limitWindowSeconds / 60
        }

        private static func flexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> Int {
            if let int = try? container.decode(Int.self, forKey: key) {
                return int
            }
            if let double = try? container.decode(Double.self, forKey: key) {
                return Int(double.rounded())
            }
            if let string = try? container.decode(String.self, forKey: key), let double = Double(string) {
                return Int(double.rounded())
            }
            throw DecodingError.dataCorrupted(.init(codingPath: [key], debugDescription: "Expected number"))
        }
    }

    struct AdditionalRateLimit: Decodable {
        var limitName: String?
        var meteredFeature: String?
        var rateLimit: RateLimitDetails?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitName = try? container.decodeIfPresent(String.self, forKey: .limitName)
            meteredFeature = try? container.decodeIfPresent(String.self, forKey: .meteredFeature)
            rateLimit = try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
        }
    }

    private struct LossyAdditionalRateLimit: Decodable {
        var value: AdditionalRateLimit?

        init(from decoder: Decoder) throws {
            value = try? AdditionalRateLimit(from: decoder)
        }
    }
}

nonisolated enum CodexProfileAnalyticsError: Error, Equatable {
    case authenticationRequired
}

nonisolated struct CodexProfileAnalyticsFetcher: Sendable {
    private static let profileURL = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!

    let urlSession: URLSession
    var now: @Sendable () -> Date = Date.init

    init(urlSession: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.urlSession = urlSession
        self.now = now
    }

    func fetch(accessToken: String, accountID: String?) async throws -> QuotaAnalytics? {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "Originator")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CodexProfileAnalyticsError.authenticationRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let profile = try CodexProfileAnalyticsResponse(data: data)
        return Self.analytics(from: profile, now: now())
    }

    static func analytics(from response: CodexProfileAnalyticsResponse, now: Date = Date()) -> QuotaAnalytics? {
        guard let stats = response.stats else { return nil }

        var rows: [QuotaAnalyticsRow] = []
        let calendar = Calendar.current
        let today = dayString(now, calendar: calendar)
        let yesterday = dayString(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
        let bucketsByDate = Dictionary(uniqueKeysWithValues: stats.dailyUsageBuckets.map { ($0.date, $0.tokens) })

        rows.append(dayRow(id: "today", title: "Today", tokens: bucketsByDate[today]))
        rows.append(dayRow(id: "yesterday", title: "Yesterday", tokens: bucketsByDate[yesterday]))

        let latest30 = stats.dailyUsageBuckets.sorted { $0.date > $1.date }.prefix(30)
        let last30Tokens = latest30.reduce(0) { $0 + $1.tokens }
        rows.append(last30Tokens > 0
            ? QuotaAnalyticsRow(id: "last-30-days", title: "Last 30 Days", value: tokenLabel(last30Tokens))
            : .noData(id: "last-30-days", title: "Last 30 Days"))

        appendTokenRow(&rows, id: "codex-lifetime-tokens", title: "Lifetime Tokens", value: stats.lifetimeTokens)
        appendTokenRow(&rows, id: "codex-peak-daily", title: "Peak Daily", value: stats.peakDailyTokens)
        appendDurationRow(&rows, id: "codex-longest-task", title: "Longest Task", seconds: stats.longestRunningTurnSeconds)
        appendDaysRow(&rows, id: "codex-current-streak", title: "Current Streak", value: stats.currentStreakDays)
        appendDaysRow(&rows, id: "codex-longest-streak", title: "Longest Streak", value: stats.longestStreakDays)

        let trend = stats.dailyUsageBuckets
            .sorted { $0.date < $1.date }
            .suffix(371)
            .map {
                QuotaAnalyticsPoint(
                    date: $0.date,
                    value: Double($0.tokens),
                    label: $0.date,
                    valueLabel: tokenLabel($0.tokens)
                )
            }

        let analytics = QuotaAnalytics(trend: trend, rows: rows, note: "Account analytics from Codex")
        return analytics.isEmpty ? nil : analytics
    }

    private static func dayRow(id: String, title: String, tokens: Int?) -> QuotaAnalyticsRow {
        guard let tokens, tokens > 0 else {
            return .noData(id: id, title: title)
        }
        return QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(tokens))
    }

    private static func appendTokenRow(_ rows: inout [QuotaAnalyticsRow], id: String, title: String, value: Int?) {
        guard let value, value > 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(value)))
    }

    private static func appendDaysRow(_ rows: inout [QuotaAnalyticsRow], id: String, title: String, value: Int?) {
        guard let value, value >= 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: "\(intLabel(value)) \(value == 1 ? "day" : "days")"))
    }

    private static func appendDurationRow(_ rows: inout [QuotaAnalyticsRow], id: String, title: String, seconds: Int?) {
        guard let seconds, seconds > 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: durationLabel(seconds)))
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func tokenLabel(_ value: Int) -> String {
        "\(compactNumber(Double(value))) tokens"
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }

    private static func compactNumber(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
        }
        if absValue >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if absValue >= 1_000 {
            return String(format: "%.1fK", value / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        return intLabel(Int(value))
    }

    private static func intLabel(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

nonisolated struct CodexProfileAnalyticsResponse: Equatable, Sendable {
    var stats: Stats?

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected object"))
        }
        self.init(json: json)
    }

    init(json: [String: Any]) {
        stats = (json["stats"] as? [String: Any]).map(Stats.init(json:))
    }

    nonisolated struct Stats: Equatable, Sendable {
        var lifetimeTokens: Int?
        var peakDailyTokens: Int?
        var currentStreakDays: Int?
        var longestStreakDays: Int?
        var longestRunningTurnSeconds: Int?
        var dailyUsageBuckets: [UsageBucket]

        init(json: [String: Any]) {
            lifetimeTokens = intValue(json["lifetime_tokens"] ?? json["lifetimeTokens"])
            peakDailyTokens = intValue(json["peak_daily_tokens"] ?? json["peakDailyTokens"])
            currentStreakDays = intValue(json["current_streak_days"] ?? json["currentStreakDays"])
            longestStreakDays = intValue(json["longest_streak_days"] ?? json["longestStreakDays"])
            longestRunningTurnSeconds = intValue(json["longest_running_turn_sec"] ?? json["longestRunningTurnSec"])
            dailyUsageBuckets = UsageBucket.decodeBuckets(json["daily_usage_buckets"] ?? json["dailyUsageBuckets"])
        }
    }

    nonisolated struct UsageBucket: Equatable, Sendable {
        var date: String
        var tokens: Int

        static func decodeBuckets(_ value: Any?) -> [UsageBucket] {
            if let array = value as? [Any] {
                return array.compactMap(bucket(from:))
            }
            if let object = value as? [String: Any] {
                return object.compactMap { key, value in
                    guard let tokens = tokenCount(from: value) else { return nil }
                    return UsageBucket(date: normalizeDate(key), tokens: tokens)
                }
            }
            return []
        }

        private static func bucket(from value: Any) -> UsageBucket? {
            guard let object = value as? [String: Any] else { return nil }
            guard let date = stringValue(
                object["date"]
                    ?? object["day"]
                    ?? object["start_date"]
                    ?? object["startDate"]
                    ?? object["bucket"]
                    ?? object["bucket_start"]
                    ?? object["bucketStart"]
            ) else {
                return nil
            }
            guard let tokens = tokenCount(from: object) else { return nil }
            return UsageBucket(date: normalizeDate(date), tokens: tokens)
        }

        private static func tokenCount(from value: Any?) -> Int? {
            if let object = value as? [String: Any] {
                if let total = intValue(
                    object["tokens"]
                        ?? object["token_count"]
                        ?? object["tokenCount"]
                        ?? object["total_tokens"]
                        ?? object["totalTokens"]
                        ?? object["value"]
                        ?? object["count"]
                ) {
                    return total
                }
                let input = intValue(object["input_tokens"] ?? object["inputTokens"]) ?? 0
                let output = intValue(object["output_tokens"] ?? object["outputTokens"]) ?? 0
                return input + output > 0 ? input + output : nil
            }
            return intValue(value)
        }

        private static func normalizeDate(_ value: String) -> String {
            if value.count >= 10 {
                return String(value.prefix(10))
            }
            return value
        }
    }
}

nonisolated func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        value
    case let value as CustomStringConvertible:
        value.description
    default:
        nil
    }
}

nonisolated func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        value
    case let value as Int:
        Double(value)
    case let value as String:
        Double(value)
    default:
        nil
    }
}

nonisolated func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        value
    case let value as Double:
        Int(value)
    case let value as String:
        Int(value) ?? Double(value).map(Int.init)
    default:
        nil
    }
}

nonisolated func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
