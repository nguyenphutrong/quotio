import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain

public final class AmpNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  public override init() {}

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public actor AmpQuotaFetcher: QuotaFetching {
  private struct Response: Decodable {
    struct Result: Decodable { let displayText: String? }
    struct APIError: Decodable { let code: String? }
    let ok: Bool?
    let result: Result?
    let error: APIError?
  }

  public static let localAccountKey = ProviderAccountKey.ampNative
  public static let defaultNativePath = "~/.local/share/amp/secrets.json"
  public nonisolated let provider = QuotaProvider.amp
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let files: any QuotaCredentialFileReading
  private let session: any QuotaHTTPSession
  private let nativePath: String
  private let endpoint: URL
  private let now: @Sendable () -> Date

  public init(
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    session: (any QuotaHTTPSession)? = nil,
    nativePath: String = AmpQuotaFetcher.defaultNativePath,
    endpoint: URL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.vault = vault
    self.metadata = metadata
    self.files = files
    self.nativePath = nativePath
    self.endpoint = endpoint
    self.now = now
    self.session =
      session
      ?? URLSession(
        configuration: Self.sessionConfiguration(),
        delegate: AmpNoRedirectDelegate(),
        delegateQueue: nil
      )
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let disabled = await metadata.disabledAccountIDs()
    var quotas: [String: ProviderQuota] = [:]
    var hasCredential = false

    if Self.includes(Self.localAccountKey, in: request.scope),
      !disabled.contains(Self.localAccountID(path: nativePath)),
      let token = await nativeToken()
    {
      hasCredential = true
      if let quota = try? await fetchQuota(token: token) { quotas[Self.localAccountKey] = quota }
    }

    if request.mode == .monitor {
      for account in await vault.accounts()
      where account.providerID.rawValue == provider.rawValue
        && !disabled.contains(account.id)
        && Self.includes(account.accountKey, in: request.scope)
      {
        guard let credential = await vault.credential(for: account.id),
          !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { continue }
        hasCredential = true
        if let quota = try? await fetchQuota(token: credential.accessToken) {
          quotas[account.accountKey] = quota
        }
      }
    }
    return QuotaProviderOutput(
      quotas: quotas, credentialAvailability: hasCredential ? .present : .missing)
  }

  public nonisolated static func localAccountID(path: String = defaultNativePath) -> String {
    AccountIdentity.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.amp.rawValue),
      accountKey: localAccountKey
    ).id
  }

  public nonisolated static func request(
    apiKey: String,
    endpoint: URL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!
  ) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpShouldHandleCookies = false
    return request
  }

  public nonisolated static func sessionConfiguration(defaults: UserDefaults = .standard)
    -> URLSessionConfiguration
  {
    let proxied = ProxyURLSessionFactory.makeConfiguration(timeout: 15, defaults: defaults)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = proxied.timeoutIntervalForRequest
    configuration.connectionProxyDictionary = proxied.connectionProxyDictionary
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return configuration
  }

  private func nativeToken() async -> String? {
    guard let data = await files.read(path: nativePath),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    for key in ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"] {
      if let token = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !token.isEmpty
      {
        return token
      }
    }
    return nil
  }

  private func fetchQuota(token: String) async throws -> ProviderQuota {
    let (data, response) = try await session.data(
      for: Self.request(apiKey: token, endpoint: endpoint))
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      return ProviderQuota(lastUpdated: now(), isForbidden: true)
    }
    guard 200...299 ~= http.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(Response.self, from: data)
    if decoded.error?.code == "auth-required" {
      return ProviderQuota(lastUpdated: now(), isForbidden: true)
    }
    guard decoded.ok != false, let text = decoded.result?.displayText,
      let quota = Self.parse(text, now: now())
    else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return quota
  }

  nonisolated static func parse(_ displayText: String, now: Date) -> ProviderQuota? {
    let text = displayText.replacingOccurrences(
      of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    let identity = captures(#"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#, text)
    var plan = identity.flatMap { $0[1].isEmpty ? nil : $0[1] }
    var metrics: [QuotaMetric] = []
    if let match = captures(
      #"(?im)^\s*Amp Free:\s*\$?([\d,]+(?:\.\d+)?)\s*/\s*\$?([\d,]+(?:\.\d+)?)\s+remaining(?:\s*\(replenishes\s*\+\$?([\d,]+(?:\.\d+)?)\s*/\s*hour\))?"#,
      text),
      let remaining = dollars(match[0]), let limit = dollars(match[1]), limit > 0,
      (0...limit).contains(remaining)
    {
      let used = limit - remaining
      let hourly = dollars(match[2]) ?? 0
      let reset =
        hourly > 0
        ? ISO8601DateFormatter().string(from: now.addingTimeInterval(used / hourly * 3600)) : ""
      metrics.append(
        QuotaMetric(
          name: "amp-free", percentage: remaining / limit * 100, resetTime: reset,
          presentation: .progress(used: used, limit: limit, unit: .usd)))
    } else if let match = captures(#"(?im)^\s*Amp Free:\s*([\d.]+)%\s+remaining"#, text),
      let remaining = percentage(match[0])
    {
      metrics.append(
        QuotaMetric(name: "amp-free", percentage: remaining, resetTime: nextMidnight(after: now)))
    }
    if let match = captures(
      #"(?im)^\s*Amp\s+([^:\r\n]+?)\s+Subscription:\s*([\d.]+)%\s+(?:other|agent)\s+usage\s+and\s+([\d.]+)%\s+orb\s+usage\s+remaining\b(?:\s*-\s*resets\s+upon\s+renewal\s+in\s+(\d+)\s+(minutes?|hours?|days?|weeks?|months?|years?))?"#,
      text),
      let agent = percentage(match[1]), let orb = percentage(match[2])
    {
      plan = match[0]
      let reset = relativeReset(match[3], match[4], now)
      metrics.insert(
        QuotaMetric(name: "amp-agent-usage", percentage: agent, resetTime: reset), at: 0)
      metrics.insert(QuotaMetric(name: "amp-orb-usage", percentage: orb, resetTime: reset), at: 1)
    }
    if let match = captures(
      #"(?im)^\s*Individual credits:\s*\$?([\d,]+(?:\.\d+)?)\s+remaining"#, text),
      let value = dollars(match[0])
    {
      metrics.append(amount("amp-individual-credits", value))
    }
    for match in allCaptures(
      #"(?im)^\s*Workspace\s+(.+?):\s*\$?([\d,]+(?:\.\d+)?)\s+remaining"#, text)
    {
      guard let value = dollars(match[1]) else { continue }
      metrics.append(
        QuotaMetric(
          name: "amp-workspace-" + stableID(match[0]), percentage: -1, resetTime: "",
          presentation: .amount(value: value, unit: .usd, semantics: .balance), tooltip: match[0]))
    }
    guard !metrics.isEmpty else { return nil }
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: plan, accountDisplayName: identity?.first)
  }

  private nonisolated static func captures(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (1..<match.numberOfRanges).map { rangeString(match.range(at: $0), text) }
  }
  private nonisolated static func allCaptures(_ pattern: String, _ text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
      (1..<match.numberOfRanges).map { rangeString(match.range(at: $0), text) }
    }
  }
  private nonisolated static func rangeString(_ range: NSRange, _ text: String) -> String {
    guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
    return String(text[swiftRange])
  }
  private nonisolated static func dollars(_ value: String) -> Double? {
    Double(value.replacingOccurrences(of: ",", with: ""))
  }
  private nonisolated static func percentage(_ value: String) -> Double? {
    Double(value).flatMap { (0...100).contains($0) ? $0 : nil }
  }
  private nonisolated static func amount(_ name: String, _ value: Double) -> QuotaMetric {
    QuotaMetric(
      name: name, percentage: -1, resetTime: "",
      presentation: .amount(value: value, unit: .usd, semantics: .balance))
  }
  private nonisolated static func nextMidnight(after date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return ISO8601DateFormatter().string(
      from: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!)
  }
  private nonisolated static func relativeReset(_ value: String, _ unit: String, _ date: Date)
    -> String
  {
    guard let value = Int(value) else { return "" }
    let component: Calendar.Component
    switch unit.lowercased() {
    case "minute", "minutes": component = .minute
    case "hour", "hours": component = .hour
    case "day", "days": component = .day
    case "week", "weeks": component = .weekOfYear
    case "month", "months": component = .month
    case "year", "years": component = .year
    default: return ""
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(byAdding: component, value: value, to: date).map(
      ISO8601DateFormatter().string) ?? ""
  }
  private nonisolated static func stableID(_ value: String) -> String {
    SHA256.hash(data: Data(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
      .prefix(8).map { String(format: "%02x", $0) }.joined()
  }
  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
