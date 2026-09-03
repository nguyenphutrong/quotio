import Foundation
import QuotioApplication
import QuotioDomain

public actor WarpQuotaFetcher: QuotaFetching {
  private struct Response: Decodable {
    let data: DataWrapper?
    struct DataWrapper: Decodable { let user: UserOutput? }
    struct UserOutput: Decodable { let user: User? }
    struct User: Decodable {
      let requestLimitInfo: RequestLimitInfo?
      let workspaces: [Workspace]?
      let bonusGrants: [BonusGrant]?
    }
    struct RequestLimitInfo: Decodable {
      let isUnlimited: Bool?
      let nextRefreshTime: String?
      let requestLimit: Int?
      let requestsUsedSinceLastRefresh: Int?
    }
    struct Workspace: Decodable { let bonusGrantsInfo: BonusGrantsInfo? }
    struct BonusGrantsInfo: Decodable { let grants: [BonusGrant]? }
    struct BonusGrant: Decodable {
      let expiration: String?
      let userFacingMessage: String?
      let requestCreditsGranted: Int?
      let requestCreditsRemaining: Int?
    }
  }

  public nonisolated let provider = QuotaProvider.warp
  private let repository: any WarpTokenRepository
  private let session: any QuotaHTTPSession
  private let endpoint: URL
  private let now: @Sendable () -> Date

  public init(
    repository: any WarpTokenRepository,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)
    ),
    endpoint: URL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.repository = repository
    self.session = session
    self.endpoint = endpoint
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let tokens = try repository.load().filter {
      $0.isEnabled && Self.includes($0.name, in: request.scope)
    }
    let hasCredential = tokens.contains {
      !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var quotas: [String: ProviderQuota] = [:]
    for entry in tokens {
      guard !entry.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      if let quota = try? await fetchQuota(apiKey: entry.token) {
        quotas[entry.name] = quota
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: hasCredential ? .present : .missing
    )
  }

  private func fetchQuota(apiKey: String) async throws -> ProviderQuota {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("warp-app", forHTTPHeaderField: "x-warp-client-id")
    request.setValue("v0.2026.01.07.08.13.stable_01", forHTTPHeaderField: "x-warp-client-version")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody())

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    guard 200...299 ~= response.statusCode else {
      if response.statusCode == 401 || response.statusCode == 403 {
        return ProviderQuota(lastUpdated: now(), isForbidden: true)
      }
      throw InfrastructureQuotaFetchError.httpError(response.statusCode)
    }
    let decoded = try JSONDecoder().decode(Response.self, from: data)
    guard let user = decoded.data?.user?.user,
      let info = user.requestLimitInfo
    else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return map(info: info, workspaces: user.workspaces ?? [], grants: user.bonusGrants ?? [])
  }

  private func map(
    info: Response.RequestLimitInfo,
    workspaces: [Response.Workspace],
    grants: [Response.BonusGrant]
  ) -> ProviderQuota {
    let used = info.requestsUsedSinceLastRefresh ?? 0
    let limit = info.requestLimit ?? 0
    let remaining = max(0, limit - used)
    let percentage =
      info.isUnlimited == true
      ? 100
      : limit > 0
        ? Self.clamp(Double(remaining) / Double(limit) * 100) : 0
    var metrics = [
      QuotaMetric(
        name: "warp-usage", percentage: percentage,
        resetTime: Self.stripMilliseconds(info.nextRefreshTime) ?? "",
        used: used, limit: limit, remaining: remaining
      )
    ]
    let allGrants = workspaces.flatMap { $0.bonusGrantsInfo?.grants ?? [] } + grants
    for (index, grant) in allGrants.enumerated() {
      guard let granted = grant.requestCreditsGranted,
        let remaining = grant.requestCreditsRemaining,
        granted > 0
      else { continue }
      metrics.append(
        QuotaMetric(
          name: "warp-bonus-\(index)",
          percentage: Self.clamp(Double(remaining) / Double(granted) * 100),
          resetTime: Self.stripMilliseconds(grant.expiration) ?? "",
          used: granted - remaining,
          limit: granted,
          remaining: remaining,
          tooltip: grant.userFacingMessage
        ))
    }
    return ProviderQuota(models: metrics, lastUpdated: now())
  }

  private nonisolated static func includes(_ name: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let account): account == name
    case .importedAccounts(let accounts): accounts.contains(name)
    }
  }

  private nonisolated static func stripMilliseconds(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.replacingOccurrences(
      of: #"\.(\d+)Z$"#, with: "Z", options: .regularExpression
    )
  }

  private nonisolated static func clamp(_ value: Double) -> Double {
    min(100, max(0, value))
  }

  private func requestBody() -> [String: Any] {
    [
      "query": """
      query GetRequestLimitInfo($requestContext: RequestContext!) {
        user(requestContext: $requestContext) {
          __typename
          ... on UserOutput { user {
            requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh }
            workspaces { uid bonusGrantsInfo { grants { createdAt costCents expiration reason userFacingMessage requestCreditsGranted requestCreditsRemaining } spendingInfo { currentMonthCreditsPurchased currentMonthPeriodEnd currentMonthSpendCents } } }
            bonusGrants { createdAt costCents expiration reason userFacingMessage requestCreditsGranted requestCreditsRemaining }
          } }
        }
      }
      """,
      "variables": [
        "requestContext": [
          "clientContext": [:],
          "osContext": [
            "category": "macOS", "name": "macOS", "version": "26.2",
          ],
        ]
      ],
      "operationName": "GetRequestLimitInfo",
    ]
  }
}
