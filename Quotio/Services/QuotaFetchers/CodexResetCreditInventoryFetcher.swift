import CryptoKit
import Foundation

nonisolated struct CodexResetCreditInventoryFetcher: Sendable {
    private static let inventoryURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    let urlSession: URLSession
    var now: @Sendable () -> Date = Date.init

    init(urlSession: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.urlSession = urlSession
        self.now = now
    }

    func fetchAnalytics(accessToken: String, accountID: String?) async throws -> QuotaAnalytics? {
        var request = URLRequest(url: Self.inventoryURL, timeoutInterval: 4)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
        let payload = try decoder.decode(CodexResetCreditInventoryResponse.self, from: data)
        guard payload.availableCount >= 0 else { return nil }

        let snapshot = CodexResetCreditInventorySnapshot(
            credits: payload.credits.map(\.model),
            availableCount: payload.availableCount,
            updatedAt: now()
        )
        return Self.analytics(from: snapshot)
    }

    private static func analytics(from snapshot: CodexResetCreditInventorySnapshot) -> QuotaAnalytics? {
        var rows = [
            QuotaAnalyticsRow(
                id: "codex-rate-limit-resets",
                title: "Rate Limit Resets",
                value: "\(snapshot.availableCount) available"
            )
        ]

        rows.append(contentsOf: snapshot.availableCredits().map { credit in
            QuotaAnalyticsRow(
                id: "codex-rate-limit-reset-\(credit.id)",
                title: credit.expiryDateLabel,
                value: credit.expiryRelativeLabel(from: snapshot.updatedAt)
            )
        })

        return QuotaAnalytics(rows: rows)
    }

    static func merge(_ resetCreditAnalytics: QuotaAnalytics, into analytics: QuotaAnalytics?) -> QuotaAnalytics {
        var merged = analytics ?? QuotaAnalytics()
        let resetCreditRowIDs = Set(resetCreditAnalytics.rows.map(\.id))
        merged.rows.removeAll { resetCreditRowIDs.contains($0.id) }
        return merged.merging(resetCreditAnalytics)
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        if let date = fractional.date(from: raw) ?? standard.date(from: raw) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date"
        )
    }
}

private nonisolated struct CodexResetCreditInventoryResponse: Decodable {
    let credits: [CodexResetCreditResponse]
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
}

private nonisolated struct CodexResetCreditResponse: Decodable {
    let id: String
    let resetType: String
    let status: CodexResetCreditStatus
    let grantedAt: Date
    let expiresAt: Date?
    let redeemStartedAt: Date?
    let redeemedAt: Date?
    let title: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case redeemStartedAt = "redeem_started_at"
        case redeemedAt = "redeemed_at"
        case title
        case description
    }

    var model: CodexResetCredit {
        CodexResetCredit(
            providerID: id,
            resetType: resetType,
            status: status,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            redeemStartedAt: redeemStartedAt,
            redeemedAt: redeemedAt,
            title: title,
            description: description
        )
    }
}

private nonisolated struct CodexResetCreditInventorySnapshot: Sendable {
    let credits: [CodexResetCredit]
    let availableCount: Int
    let updatedAt: Date

    func availableCredits() -> [CodexResetCredit] {
        credits
            .filter { $0.status == .available && ($0.expiresAt.map { $0 > updatedAt } ?? true) }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.id < rhs.id
            }
    }
}

private nonisolated struct CodexResetCredit: Sendable {
    let id: String
    let resetType: String
    let status: CodexResetCreditStatus
    let grantedAt: Date
    let expiresAt: Date?
    let redeemStartedAt: Date?
    let redeemedAt: Date?
    let title: String?
    let description: String?

    init(
        providerID: String,
        resetType: String,
        status: CodexResetCreditStatus,
        grantedAt: Date,
        expiresAt: Date?,
        redeemStartedAt: Date?,
        redeemedAt: Date?,
        title: String?,
        description: String?
    ) {
        self.id = Self.stableID(for: providerID)
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeemStartedAt = redeemStartedAt
        self.redeemedAt = redeemedAt
        self.title = title
        self.description = description
    }

    var expiryDateLabel: String {
        guard let expiresAt else { return "No expiry" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM · HH:mm"
        return formatter.string(from: expiresAt)
    }

    func expiryRelativeLabel(from date: Date) -> String {
        guard let expiresAt else { return "" }
        let seconds = expiresAt.timeIntervalSince(date)
        if seconds <= 0 { return "expired" }

        let days = Int(ceil(seconds / 86_400))
        if days >= 1 {
            return "in \(days) \(days == 1 ? "day" : "days")"
        }

        let hours = Int(ceil(seconds / 3_600))
        if hours >= 1 {
            return "in \(hours) \(hours == 1 ? "hour" : "hours")"
        }

        let minutes = max(1, Int(ceil(seconds / 60)))
        return "in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    private static func stableID(for providerID: String) -> String {
        let value = "com.quotio.codex.reset-credit-id.v1\0\(providerID)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private nonisolated enum CodexResetCreditStatus: Equatable, Decodable, Sendable {
    case available
    case redeeming
    case redeemed
    case expired
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "available":
            self = .available
        case "redeeming":
            self = .redeeming
        case "redeemed":
            self = .redeemed
        case "expired":
            self = .expired
        default:
            self = .unknown(value)
        }
    }
}
