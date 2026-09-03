import Foundation
import QuotioApplication
import QuotioDomain

public struct TraeCredential: Equatable, Sendable {
  public let accessToken: String?
  public let email: String?
  public let userID: String?
  public let apiHost: String?
  public let username: String?

  public init(
    accessToken: String?, email: String?, userID: String?, apiHost: String?, username: String?
  ) {
    self.accessToken = accessToken
    self.email = email
    self.userID = userID
    self.apiHost = apiHost
    self.username = username
  }
}

public actor TraeQuotaFetcher: QuotaFetching {
  public static let storagePath =
    "~/Library/Application Support/Trae/User/globalStorage/storage.json"
  public static let applicationPaths = ["/Applications/Trae.app", "~/Applications/Trae.app"]
  public static let authKey = "iCubeAuthInfo://icube.cloudide"
  public nonisolated let provider = QuotaProvider.trae

  private let files: any QuotaCredentialFileReading
  private let applications: any IDEApplicationChecking
  private let session: any QuotaHTTPSession
  private let storagePath: String
  private let now: @Sendable () -> Date

  public init(
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    applications: any IDEApplicationChecking = LocalIDEApplicationChecker(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    storagePath: String = TraeQuotaFetcher.storagePath,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.files = files
    self.applications = applications
    self.session = session
    self.storagePath = storagePath
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard Self.allows(request), applications.isInstalled(paths: Self.applicationPaths) else {
      return .init(quotas: [:], credentialAvailability: .missing)
    }
    guard let data = await files.read(path: storagePath),
      let credential = Self.parseCredential(data),
      let token = credential.accessToken
    else {
      return .init(quotas: [:], credentialAvailability: .missing)
    }
    let key = credential.email ?? credential.username ?? credential.userID ?? "Trae User"
    guard Self.includes(key, in: request.scope) else {
      return .init(quotas: [:], credentialAvailability: .present)
    }
    let host = credential.apiHost ?? "https://api-sg-central.trae.ai"
    guard let url = URL(string: host + "/trae/api/v1/pay/user_current_entitlement_list") else {
      return .init(quotas: [:], credentialAvailability: .present)
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["require_usage": true])
    urlRequest.setValue("Cloud-IDE-JWT \(token)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    urlRequest.setValue("https://www.trae.ai", forHTTPHeaderField: "Origin")
    urlRequest.setValue("https://www.trae.ai/", forHTTPHeaderField: "Referer")
    urlRequest.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      forHTTPHeaderField: "User-Agent")
    guard let (responseData, response) = try? await session.data(for: urlRequest),
      let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      let quota = Self.map(responseData, now: now())
    else {
      return .init(quotas: [:], credentialAvailability: .present)
    }
    return .init(quotas: [key: quota], credentialAvailability: .present)
  }

  public nonisolated static func parseCredential(_ data: Data) -> TraeCredential? {
    guard let storage = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = storage[authKey] as? String,
      let nested = raw.data(using: .utf8),
      let auth = try? JSONSerialization.jsonObject(with: nested) as? [String: Any]
    else {
      return nil
    }
    let account = auth["account"] as? [String: Any]
    let result = TraeCredential(
      accessToken: auth["token"] as? String, email: account?["email"] as? String,
      userID: auth["userId"] as? String, apiHost: auth["host"] as? String,
      username: account?["username"] as? String)
    return result.accessToken != nil || result.email != nil ? result : nil
  }

  public nonisolated static func map(_ data: Data, now: Date = Date()) -> ProviderQuota? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let list = root["user_entitlement_pack_list"] as? [[String: Any]],
      let entitlement = list.first(where: { $0["status"] as? Int == 1 }) ?? list.first
    else {
      return nil
    }
    let base = entitlement["entitlement_base_info"] as? [String: Any] ?? [:]
    let limits = base["quota"] as? [String: Any] ?? [:]
    let usage = entitlement["usage"] as? [String: Any] ?? [:]
    let reset =
      (base["end_time"] as? Int).map {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
      } ?? ""
    let definitions = [
      ("premium-fast", "premium_model_fast_request_limit", "premium_model_fast_amount"),
      ("premium-slow", "premium_model_slow_request_limit", "premium_model_slow_amount"),
      ("advanced-model", "advanced_model_request_limit", "advanced_model_amount"),
      ("auto-completion", "auto_completion_limit", "auto_completion_amount"),
    ]
    var metrics = definitions.compactMap { name, limitKey, usedKey -> QuotaMetric? in
      let limit = limits[limitKey] as? Int ?? 0
      guard limit > 0 else { return nil }
      let used = usage[usedKey] as? Int ?? 0
      let remaining = max(0, limit - used)
      return .init(
        name: name, percentage: min(100, max(0, Double(remaining) / Double(limit) * 100)),
        resetTime: reset, used: used, limit: limit, remaining: remaining)
    }
    if metrics.isEmpty { metrics = [.init(name: "trae-usage", percentage: -1, resetTime: "")] }
    let plan: String? =
      switch base["product_type"] as? Int {
      case 0: "Free"
      case 1: "Pro"
      case 2: "Team"
      case 3: "Builder"
      default: nil
      }
    return ProviderQuota(models: metrics, lastUpdated: now, planType: plan)
  }

  private nonisolated static func allows(_ request: QuotaFetchRequest) -> Bool {
    if case .provider = request.scope { return request.force }
    return true
  }

  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
