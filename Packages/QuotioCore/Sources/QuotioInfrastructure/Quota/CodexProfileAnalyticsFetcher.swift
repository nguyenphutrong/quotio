import Foundation
import QuotioDomain

nonisolated struct CodexProfileAnalyticsFetcher: Sendable {
  static let profileURL = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!

  let session: any QuotaHTTPSession
  var now: @Sendable () -> Date

  init(
    session: any QuotaHTTPSession,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.session = session
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

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
      return nil
    }
    return try Self.analytics(from: data, now: now())
  }

  static func analytics(from data: Data, now: Date = Date()) throws -> QuotaAnalytics? {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let stats = json["stats"] as? [String: Any]
    else { return nil }

    let buckets = usageBuckets(stats["daily_usage_buckets"] ?? stats["dailyUsageBuckets"])
    let calendar = Calendar.current
    let today = dayString(now, calendar: calendar)
    let yesterday = dayString(
      calendar.date(byAdding: .day, value: -1, to: now) ?? now,
      calendar: calendar)
    let bucketsByDate = Dictionary(uniqueKeysWithValues: buckets.map { ($0.date, $0.tokens) })
    var rows = [
      dayRow(id: "today", title: "Today", tokens: bucketsByDate[today]),
      dayRow(id: "yesterday", title: "Yesterday", tokens: bucketsByDate[yesterday]),
    ]
    let last30Tokens = buckets.sorted { $0.date > $1.date }.prefix(30).reduce(0) {
      $0 + $1.tokens
    }
    rows.append(
      last30Tokens > 0
        ? QuotaAnalyticsRow(
          id: "last-30-days", title: "Last 30 Days", value: tokenLabel(last30Tokens))
        : noDataRow(id: "last-30-days", title: "Last 30 Days"))
    appendTokenRow(
      &rows, id: "codex-lifetime-tokens", title: "Lifetime Tokens",
      value: intValue(stats["lifetime_tokens"] ?? stats["lifetimeTokens"]))
    appendTokenRow(
      &rows, id: "codex-peak-daily", title: "Peak Daily",
      value: intValue(stats["peak_daily_tokens"] ?? stats["peakDailyTokens"]))
    appendDurationRow(
      &rows, id: "codex-longest-task", title: "Longest Task",
      seconds: intValue(stats["longest_running_turn_sec"] ?? stats["longestRunningTurnSec"]))
    appendDaysRow(
      &rows, id: "codex-current-streak", title: "Current Streak",
      value: intValue(stats["current_streak_days"] ?? stats["currentStreakDays"]))
    appendDaysRow(
      &rows, id: "codex-longest-streak", title: "Longest Streak",
      value: intValue(stats["longest_streak_days"] ?? stats["longestStreakDays"]))

    let trend = buckets.sorted { $0.date < $1.date }.suffix(371).map {
      QuotaAnalyticsPoint(
        date: $0.date,
        value: Double($0.tokens),
        label: $0.date,
        valueLabel: tokenLabel($0.tokens))
    }
    let analytics = QuotaAnalytics(
      trend: trend,
      rows: rows,
      note: "Account analytics from Codex")
    return analytics.isEmpty ? nil : analytics
  }

  private static func usageBuckets(_ value: Any?) -> [UsageBucket] {
    if let array = value as? [Any] {
      return array.compactMap { value in
        guard let object = value as? [String: Any],
          let date = stringValue(
            object["date"] ?? object["day"] ?? object["start_date"]
              ?? object["startDate"] ?? object["bucket"] ?? object["bucket_start"]
              ?? object["bucketStart"]),
          let tokens = tokenCount(object)
        else { return nil }
        return UsageBucket(date: normalizeDate(date), tokens: tokens)
      }
    }
    if let object = value as? [String: Any] {
      return object.compactMap { date, value in
        tokenCount(value).map { UsageBucket(date: normalizeDate(date), tokens: $0) }
      }
    }
    return []
  }

  private static func tokenCount(_ value: Any?) -> Int? {
    guard let object = value as? [String: Any] else { return intValue(value) }
    if let total = intValue(
      object["tokens"] ?? object["token_count"] ?? object["tokenCount"]
        ?? object["total_tokens"] ?? object["totalTokens"] ?? object["value"]
        ?? object["count"])
    {
      return total
    }
    let input = intValue(object["input_tokens"] ?? object["inputTokens"]) ?? 0
    let output = intValue(object["output_tokens"] ?? object["outputTokens"]) ?? 0
    return input + output > 0 ? input + output : nil
  }

  private static func normalizeDate(_ value: String) -> String {
    value.count >= 10 ? String(value.prefix(10)) : value
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String: value
    case let value as CustomStringConvertible: value.description
    default: nil
    }
  }

  private static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int: value
    case let value as Double: Int(value)
    case let value as String: Int(value) ?? Double(value).map(Int.init)
    default: nil
    }
  }

  private static func dayRow(id: String, title: String, tokens: Int?) -> QuotaAnalyticsRow {
    guard let tokens, tokens > 0 else { return noDataRow(id: id, title: title) }
    return QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(tokens))
  }

  private static func noDataRow(id: String, title: String) -> QuotaAnalyticsRow {
    QuotaAnalyticsRow(id: id, title: title, value: "No data", isAvailable: false)
  }

  private static func appendTokenRow(
    _ rows: inout [QuotaAnalyticsRow], id: String, title: String, value: Int?
  ) {
    guard let value, value > 0 else { return }
    rows.append(QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(value)))
  }

  private static func appendDaysRow(
    _ rows: inout [QuotaAnalyticsRow], id: String, title: String, value: Int?
  ) {
    guard let value, value >= 0 else { return }
    rows.append(
      QuotaAnalyticsRow(
        id: id, title: title, value: "\(intLabel(value)) \(value == 1 ? "day" : "days")"))
  }

  private static func appendDurationRow(
    _ rows: inout [QuotaAnalyticsRow], id: String, title: String, seconds: Int?
  ) {
    guard let seconds, seconds > 0 else { return }
    rows.append(QuotaAnalyticsRow(id: id, title: title, value: durationLabel(seconds)))
  }

  private static func dayString(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0)
  }

  private static func tokenLabel(_ value: Int) -> String {
    "\(compactNumber(Double(value))) tokens"
  }

  private static func durationLabel(_ seconds: Int) -> String {
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(remainingSeconds)s" }
    return "\(remainingSeconds)s"
  }

  private static func compactNumber(_ value: Double) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000_000 {
      return String(format: "%.1fB", value / 1_000_000_000)
        .replacingOccurrences(of: ".0B", with: "B")
    }
    if absolute >= 1_000_000 {
      return String(format: "%.1fM", value / 1_000_000)
        .replacingOccurrences(of: ".0M", with: "M")
    }
    if absolute >= 1_000 {
      return String(format: "%.1fK", value / 1_000)
        .replacingOccurrences(of: ".0K", with: "K")
    }
    return intLabel(Int(value))
  }

  private static func intLabel(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }

  private struct UsageBucket {
    let date: String
    let tokens: Int
  }
}
