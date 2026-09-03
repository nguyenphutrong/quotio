import Foundation
import QuotioApplication
import QuotioDomain

public actor GLMQuotaFetcher: QuotaFetching {
  private struct QuotaResponse: Decodable {
    let code: Int?
    let msg: String?
    let data: QuotaData?
    let success: Bool?
  }

  private struct QuotaData: Decodable {
    let limits: [Limit]
  }

  private struct Limit: Decodable {
    let type: String?
    let name: String?
    let unit: Double?
    let number: Double?
    let usage: Double?
    let currentValue: Double?
    let percentage: Double?
    let nextResetTime: Double?
  }

  private struct SubscriptionResponse: Decodable {
    let data: [Subscription]?
  }

  private struct Subscription: Decodable {
    let productName: String?
  }

  public nonisolated let provider = QuotaProvider.glm
  private let repository: any CustomProviderRepository
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date

  public init(
    repository: any CustomProviderRepository,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)
    ),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.repository = repository
    self.session = session
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let providers = try repository.load().filter {
      $0.type == .glmCompatibility && $0.isEnabled && Self.includes($0.name, in: request.scope)
    }
    let hasCredential = providers.contains { !$0.apiKeys.isEmpty }
    var quotas: [String: ProviderQuota] = [:]
    for customProvider in providers {
      for entry in customProvider.apiKeys {
        if let quota = try? await fetchQuota(apiKey: entry.apiKey, baseURL: customProvider.baseURL)
        {
          quotas[customProvider.name] = quota
        }
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: hasCredential ? .present : .missing
    )
  }

  private func fetchQuota(apiKey: String, baseURL: String) async throws -> ProviderQuota {
    guard let root = Self.apiRoot(from: baseURL),
      let quotaURL = URL(string: root + "/api/monitor/usage/quota/limit")
    else {
      throw InfrastructureQuotaFetchError.invalidURL
    }
    async let subscriptionName = fetchSubscriptionName(apiKey: apiKey, root: root)
    let (data, response) = try await send(apiKey: apiKey, url: quotaURL)
    guard 200...299 ~= response.statusCode else {
      if response.statusCode == 401 || response.statusCode == 403 {
        return ProviderQuota(lastUpdated: now(), isForbidden: true)
      }
      throw InfrastructureQuotaFetchError.httpError(response.statusCode)
    }
    let decoded = try JSONDecoder().decode(QuotaResponse.self, from: data)
    guard decoded.success != false,
      decoded.code.map({ $0 == 200 }) ?? true,
      let quotaData = decoded.data
    else {
      throw InfrastructureQuotaFetchError.apiError(decoded.msg ?? "Z.ai quota unavailable")
    }
    return map(quotaData, planName: await subscriptionName)
  }

  private func send(apiKey: String, url: URL) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return (data, response)
  }

  private func fetchSubscriptionName(apiKey: String, root: String) async -> String? {
    guard let url = URL(string: root + "/api/biz/subscription/list"),
      let (data, response) = try? await send(apiKey: apiKey, url: url),
      200...299 ~= response.statusCode,
      let name = (try? JSONDecoder().decode(SubscriptionResponse.self, from: data))?
        .data?.first?.productName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else { return nil }
    return name
  }

  private func map(_ data: QuotaData, planName: String?) -> ProviderQuota {
    var metrics: [QuotaMetric] = []
    for limit in data.limits {
      let reset =
        limit.nextResetTime.map {
          ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1_000))
        } ?? ""
      let kind = limit.type ?? limit.name
      if kind == "TOKENS_LIMIT" || kind == "CREDIT_LIMIT",
        let percentage = limit.percentage,
        let unit = limit.unit,
        let number = limit.number,
        let name = Self.tokenWindowName(unit: unit, number: number)
      {
        metrics.append(
          QuotaMetric(name: name, percentage: Self.clamp(100 - percentage), resetTime: reset))
      } else if kind == "TIME_LIMIT",
        let used = limit.currentValue,
        let quotaLimit = limit.usage,
        used >= 0, quotaLimit >= 0
      {
        let remaining = quotaLimit > 0 ? Self.clamp((quotaLimit - used) / quotaLimit * 100) : 0
        metrics.append(
          QuotaMetric(
            name: "zai-web-searches", percentage: remaining, resetTime: reset,
            presentation: .progress(used: used, limit: quotaLimit, unit: .searches),
            used: Int(used), limit: Int(quotaLimit)
          ))
      }
    }
    return ProviderQuota(models: metrics, lastUpdated: now(), planType: planName)
  }

  private nonisolated static func apiRoot(from baseURL: String) -> String? {
    guard let components = URLComponents(string: baseURL),
      let scheme = components.scheme, let host = components.host
    else { return nil }
    return scheme + "://" + host + components.port.map { ":\($0)" }.orEmpty
  }

  private nonisolated static func tokenWindowName(unit: Double, number: Double) -> String? {
    guard number > 0 else { return nil }
    switch unit {
    case 3: return number < 24 ? "zai-session" : "zai-daily"
    case 4: return number <= 1 ? "zai-daily" : (number < 28 ? "zai-weekly" : "zai-monthly")
    case 5: return "zai-monthly"
    case 6: return number < 4 ? "zai-weekly" : "zai-monthly"
    default: return nil
    }
  }

  private nonisolated static func includes(_ name: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let account): account == name
    case .importedAccounts(let accounts): accounts.contains(name)
    }
  }

  private nonisolated static func clamp(_ value: Double) -> Double { min(100, max(0, value)) }
}

extension Optional where Wrapped == String {
  fileprivate var orEmpty: String { self ?? "" }
}
