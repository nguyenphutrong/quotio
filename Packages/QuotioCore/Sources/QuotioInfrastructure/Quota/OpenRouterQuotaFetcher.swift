import Foundation
import QuotioApplication
import QuotioDomain

public actor OpenRouterQuotaFetcher: QuotaFetching {
  private struct EndpointResult: Sendable {
    let data: Data?
    let status: Int?
    var succeeded: Bool { status.map { 200...299 ~= $0 } == true && data != nil }
    var forbidden: Bool { status == 401 || status == 403 }
  }

  public nonisolated let provider = QuotaProvider.openRouter
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let session: any QuotaHTTPSession
  private let creditsURL: URL
  private let keyURL: URL
  private let now: @Sendable () -> Date

  public init(
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    creditsURL: URL = URL(string: "https://openrouter.ai/api/v1/credits")!,
    keyURL: URL = URL(string: "https://openrouter.ai/api/v1/key")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.vault = vault
    self.metadata = metadata
    self.session = session
    self.creditsURL = creditsURL
    self.keyURL = keyURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard request.mode == .monitor else {
      return QuotaProviderOutput(
        quotas: [:], credentialAvailability: .missing, credentialAccountKeys: []
      )
    }
    let disabled = await metadata.disabledAccountIDs()
    let accounts = await vault.accounts().filter {
      $0.providerID.rawValue == provider.rawValue && !disabled.contains($0.id)
        && Self.includes($0.accountKey, in: request.scope)
    }
    var quotas: [String: ProviderQuota] = [:]
    var credentialAccountKeys = Set<String>()
    for account in accounts {
      guard let credential = await vault.credential(for: account.id),
        !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      credentialAccountKeys.insert(account.accountKey)
      async let credits = endpoint(creditsURL, token: credential.accessToken)
      async let key = endpoint(keyURL, token: credential.accessToken)
      if let quota = Self.map(credits: await credits, key: await key, now: now()) {
        quotas[account.accountKey] = quota
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: credentialAccountKeys.isEmpty ? .missing : .present,
      credentialAccountKeys: credentialAccountKeys
    )
  }

  private func endpoint(_ url: URL, token: String) async -> EndpointResult {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse
    else {
      return EndpointResult(data: nil, status: nil)
    }
    return EndpointResult(data: data, status: http.statusCode)
  }

  private nonisolated static func map(credits: EndpointResult, key: EndpointResult, now: Date)
    -> ProviderQuota?
  {
    guard credits.succeeded || key.succeeded else {
      return credits.forbidden || key.forbidden
        ? ProviderQuota(lastUpdated: now, isForbidden: true) : nil
    }
    var metrics: [QuotaMetric] = []
    var plan: String?
    if credits.succeeded, let object = object(credits.data) {
      let payload = (object["data"] as? [String: Any]) ?? object
      let purchased = max(0, number(payload["total_credits"]) ?? 0)
      if let usage = number(payload["total_usage"]) {
        let spent = max(0, usage)
        if purchased > 0 {
          metrics.append(
            QuotaMetric(
              name: "openrouter-credits", percentage: remaining(used: spent, limit: purchased),
              resetTime: "", presentation: .progress(used: spent, limit: purchased, unit: .usd)))
        }
        metrics.append(amount("openrouter-balance", max(0, purchased - spent), .balance))
      } else if let balance = number(payload["balance"]) {
        metrics.append(amount("openrouter-balance", balance, .balance))
      }
    }
    if key.succeeded, let object = object(key.data) {
      let payload = (object["data"] as? [String: Any]) ?? object
      plan = bool(payload["is_free_tier"]) == true ? "openrouter-free" : "openrouter-pay-as-you-go"
      for (name, field) in [
        ("openrouter-today", "usage_daily"), ("openrouter-week", "usage_weekly"),
        ("openrouter-month", "usage_monthly"),
      ] {
        if let value = number(payload[field]) {
          metrics.append(amount(name, max(0, value), .spent))
        }
      }
      if let limit = number(payload["limit"]), limit > 0 {
        let used =
          number(payload["usage"]) ?? max(0, limit - (number(payload["limit_remaining"]) ?? limit))
        metrics.append(
          QuotaMetric(
            name: "openrouter-key-limit", percentage: remaining(used: used, limit: limit),
            resetTime: "", presentation: .progress(used: used, limit: limit, unit: .usd)))
      }
    }
    return ProviderQuota(models: metrics, lastUpdated: now, planType: plan)
  }

  private nonisolated static func object(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
  private nonisolated static func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }
  private nonisolated static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return Bool(value) }
    return nil
  }
  private nonisolated static func amount(
    _ name: String, _ value: Double, _ semantics: QuotaAmountSemantics
  ) -> QuotaMetric {
    QuotaMetric(
      name: name, percentage: -1, resetTime: "",
      presentation: .amount(value: value, unit: .usd, semantics: semantics))
  }
  private nonisolated static func remaining(used: Double, limit: Double) -> Double {
    min(100, max(0, (limit - used) / limit * 100))
  }
  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
