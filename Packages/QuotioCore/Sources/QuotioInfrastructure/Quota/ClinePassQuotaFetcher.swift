import Foundation
import QuotioApplication
import QuotioDomain

public actor ClinePassQuotaFetcher: QuotaFetching {
  private struct LimitsResponse: Decodable {
    let data: LimitsData
    let success: Bool
  }
  private struct LimitsData: Decodable { let limits: [Limit] }
  private struct Limit: Decodable {
    let type: String
    let percentUsed: Double
    let resetsAt: String?
  }

  public nonisolated let provider = QuotaProvider.clinePass
  private let repository: any CustomProviderRepository
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date
  private let usageURL: URL

  public init(
    repository: any CustomProviderRepository,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)
    ),
    usageURL: URL = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.repository = repository
    self.session = session
    self.usageURL = usageURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let providers = try repository.load().filter {
      $0.type == .clinePass && $0.isEnabled && Self.includes($0.name, in: request.scope)
    }
    let hasCredential = providers.contains { !$0.apiKeys.isEmpty }
    var quotas: [String: ProviderQuota] = [:]
    for customProvider in providers {
      guard let apiKey = customProvider.apiKeys.first?.apiKey else { continue }
      if let quota = try? await fetchQuota(apiKey: apiKey) {
        quotas[customProvider.name] = quota
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: hasCredential ? .present : .missing
    )
  }

  private func fetchQuota(apiKey: String) async throws -> ProviderQuota {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw InfrastructureQuotaFetchError.forbidden }
    var request = URLRequest(url: usageURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    switch response.statusCode {
    case 200: return try parse(data)
    case 401, 403: return ProviderQuota(lastUpdated: now(), isForbidden: true)
    default: throw InfrastructureQuotaFetchError.httpError(response.statusCode)
    }
  }

  private func parse(_ data: Data) throws -> ProviderQuota {
    let response = try JSONDecoder().decode(LimitsResponse.self, from: data)
    guard response.success else { throw InfrastructureQuotaFetchError.invalidResponse }
    var byName: [String: QuotaMetric] = [:]
    for limit in response.data.limits {
      guard let name = Self.metricName(limit.type) else { continue }
      byName[name] = QuotaMetric(
        name: name,
        percentage: 100 - min(100, max(0, limit.percentUsed)),
        resetTime: try Self.normalizedResetTime(limit.resetsAt)
      )
    }
    let order = ["clinepass-five-hour", "clinepass-weekly", "clinepass-monthly"]
    return ProviderQuota(models: order.compactMap { byName[$0] }, lastUpdated: now())
  }

  private nonisolated static func metricName(_ type: String) -> String? {
    switch type {
    case "five_hour": "clinepass-five-hour"
    case "weekly": "clinepass-weekly"
    case "monthly": "clinepass-monthly"
    default: nil
    }
  }

  private nonisolated static func normalizedResetTime(_ value: String?) throws -> String {
    guard let value else { return "" }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return ISO8601DateFormatter().string(from: date)
  }

  private nonisolated static func includes(_ name: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let account): account == name
    case .importedAccounts(let accounts): accounts.contains(name)
    }
  }
}
