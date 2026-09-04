import CryptoKit
import Foundation
import QuotioDomain

nonisolated struct CodexResetCreditInventoryFetcher: Sendable {
  static let inventoryURL = URL(
    string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

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
    var request = URLRequest(url: Self.inventoryURL, timeoutInterval: 4)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
    request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
    if let accountID, !accountID.isEmpty {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
      return nil
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
    let payload = try decoder.decode(Response.self, from: data)
    guard payload.availableCount >= 0 else { return nil }

    let updatedAt = now()
    var rows = [
      QuotaAnalyticsRow(
        id: "codex-rate-limit-resets",
        title: "Rate Limit Resets",
        value: "\(payload.availableCount) available")
    ]
    let availableCredits = payload.credits.filter {
      $0.status == .available && ($0.expiresAt.map { $0 > updatedAt } ?? true)
    }.sorted { lhs, rhs in
      switch (lhs.expiresAt, rhs.expiresAt) {
      case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
      case (_?, nil): return true
      case (nil, _?): return false
      default: return lhs.id < rhs.id
      }
    }
    rows.append(contentsOf: availableCredits.map { credit in
      QuotaAnalyticsRow(
        id: "codex-rate-limit-reset-\(Self.stableID(for: credit.id))",
        title: Self.expiryDateLabel(credit.expiresAt),
        value: Self.expiryRelativeLabel(credit.expiresAt, from: updatedAt))
    })
    return QuotaAnalytics(rows: rows)
  }

  static func merge(_ resetCredits: QuotaAnalytics, into analytics: QuotaAnalytics?)
    -> QuotaAnalytics
  {
    var merged = analytics ?? QuotaAnalytics()
    let resetIDs = Set(resetCredits.rows.map(\.id))
    merged.rows.removeAll { resetIDs.contains($0.id) }
    return merged.merging(resetCredits)
  }

  private static func stableID(for providerID: String) -> String {
    let value = "com.quotio.codex.reset-credit-id.v1\0\(providerID)"
    return SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func expiryDateLabel(_ date: Date?) -> String {
    guard let date else { return "No expiry" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d MMM · HH:mm"
    return formatter.string(from: date)
  }

  private static func expiryRelativeLabel(_ expiry: Date?, from date: Date) -> String {
    guard let expiry else { return "" }
    let seconds = expiry.timeIntervalSince(date)
    if seconds <= 0 { return "expired" }
    let days = Int(ceil(seconds / 86_400))
    if days >= 1 { return "in \(days) \(days == 1 ? "day" : "days")" }
    let hours = Int(ceil(seconds / 3_600))
    if hours >= 1 { return "in \(hours) \(hours == 1 ? "hour" : "hours")" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    return "in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
  }

  private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let date = fractional.date(from: value) ?? standard.date(from: value) {
      return date
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Invalid ISO-8601 date")
  }

  private struct Response: Decodable {
    let credits: [Credit]
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
      case credits
      case availableCount = "available_count"
    }
  }

  private struct Credit: Decodable {
    let id: String
    let status: Status
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
      case id
      case status
      case expiresAt = "expires_at"
    }
  }

  private enum Status: Equatable, Decodable {
    case available
    case other

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      self = try container.decode(String.self) == "available" ? .available : .other
    }
  }
}
