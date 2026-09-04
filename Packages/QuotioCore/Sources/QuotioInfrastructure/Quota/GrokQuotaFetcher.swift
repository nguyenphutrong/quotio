import Foundation
import QuotioApplication
import QuotioDomain

public protocol GrokCredentialWriting: Sendable {
  func persist(
    path: String,
    entryKey: String,
    accessToken: String,
    refreshToken: String,
    idToken: String?,
    expiresAt: Date
  ) async throws
}

public struct LocalGrokCredentialWriter: GrokCredentialWriting {
  public init() {}
  public func persist(
    path: String, entryKey: String, accessToken: String, refreshToken: String, idToken: String?,
    expiresAt: Date
  ) async throws {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url),
      var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var entry = root[entryKey] as? [String: Any]
    else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    entry["key"] = accessToken
    entry["refresh_token"] = refreshToken
    if let idToken { entry["id_token"] = idToken }
    entry["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
    root[entryKey] = entry
    let updated = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try SecureAtomicFileWriter.write(updated, to: url)
  }
}

public actor GrokQuotaFetcher: QuotaFetching {
  public struct Candidate: Sendable, Equatable {
    public let entryKey: String
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let clientID: String
    public let expiresAt: Date?
    public var displayName: String {
      Self.jwtString(idToken, claim: "email") ?? "Grok " + String(entryKey.prefix(8))
    }

    fileprivate static func jwtString(_ token: String?, claim: String) -> String? {
      guard let token else { return nil }
      let parts = token.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count > 1 else { return nil }
      var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
      guard let data = Data(base64Encoded: payload),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return json[claim] as? String
    }
  }

  public static let authPath = "~/.grok/auth.json"
  public static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
  public nonisolated let provider = QuotaProvider.grok
  private let files: any QuotaCredentialFileReading
  private let writer: any GrokCredentialWriting
  private let session: any QuotaHTTPSession
  private let authPath: String
  private let billingURL: URL
  private let settingsURL: URL
  private let refreshURL: URL
  private let now: @Sendable () -> Date

  public init(
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    writer: any GrokCredentialWriting = LocalGrokCredentialWriter(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    authPath: String = GrokQuotaFetcher.authPath,
    billingURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
    settingsURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
    refreshURL: URL = URL(string: "https://auth.x.ai/oauth2/token")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.files = files
    self.writer = writer
    self.session = session
    self.authPath = authPath
    self.billingURL = billingURL
    self.settingsURL = settingsURL
    self.refreshURL = refreshURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard let data = await files.read(path: authPath) else {
      return .init(
        quotas: [:], credentialAvailability: .missing, credentialAccountKeys: []
      )
    }
    let candidates = Self.loadCandidates(data: data).filter {
      Self.includes($0.entryKey, in: request.scope)
    }
    var quotas: [String: ProviderQuota] = [:]
    for candidate in candidates {
      if let quota = try? await fetchQuota(candidate) { quotas[candidate.entryKey] = quota }
    }
    return .init(
      quotas: quotas,
      credentialAvailability: candidates.isEmpty ? .missing : .present,
      credentialAccountKeys: Set(candidates.map(\.entryKey))
    )
  }

  public nonisolated static func loadCandidates(data: Data) -> [Candidate] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    return root.compactMap { key, raw in
      guard let entry = raw as? [String: Any], let token = trimmed(entry["key"] as? String) else {
        return nil
      }
      let clientID = trimmed(entry["oidc_client_id"] as? String) ?? clientID(key) ?? defaultClientID
      return Candidate(
        entryKey: key, accessToken: token,
        refreshToken: trimmed((entry["refresh_token"] as? String) ?? (entry["refresh"] as? String)),
        idToken: trimmed(entry["id_token"] as? String), clientID: clientID,
        expiresAt: expiry(entry, token: token))
    }.sorted { $0.entryKey < $1.entryKey }
  }

  public nonisolated static func mapBilling(
    _ data: Data, plan: String?, displayName: String, now: Date = Date()
  ) -> ProviderQuota? {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let config = body["config"] as? [String: Any],
      let period = config["currentPeriod"] as? [String: Any], let type = period["type"] as? String
    else { return nil }
    var metrics: [QuotaMetric] = []
    if type == "USAGE_PERIOD_TYPE_WEEKLY", let end = period["end"] as? String,
      let date = parseDate(end)
    {
      let used = number(config["creditUsagePercent"]) ?? 0
      metrics.append(
        .init(
          name: "grok-weekly", percentage: max(0, min(100, 100 - used)),
          resetTime: ISO8601DateFormatter().string(from: date)))
    }
    let cap = number((config["onDemandCap"] as? [String: Any])?["val"]) ?? 0
    let units = cap.rounded() == cap ? String(Int(cap)) : String(cap)
    let status = cap > 0 ? "grok-cap:\(units)" : "grok-disabled"
    metrics.append(
      .init(
        name: "grok-extra-usage", percentage: -1, resetTime: "", presentation: .status(text: status)
      ))
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: plan, accountDisplayName: displayName)
  }

  private func fetchQuota(_ original: Candidate) async throws -> ProviderQuota {
    var candidate = original
    if let expiry = candidate.expiresAt, expiry.timeIntervalSince(now()) <= 300,
      let refreshed = try? await refresh(candidate)
    {
      candidate = refreshed
    }
    var billing = try? await get(billingURL, token: candidate.accessToken)
    if let status = billing?.1.statusCode, status == 401 || status == 403,
      let refreshed = try? await refresh(candidate)
    {
      candidate = refreshed
      billing = try? await get(billingURL, token: candidate.accessToken)
    }
    guard let (data, response) = billing else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    if response.statusCode == 401 || response.statusCode == 403 {
      return ProviderQuota(
        lastUpdated: now(), isForbidden: true, accountDisplayName: candidate.displayName)
    }
    guard 200...299 ~= response.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(response.statusCode)
    }
    var plan: String?
    if let (settings, response) = try? await get(settingsURL, token: candidate.accessToken),
      200...299 ~= response.statusCode,
      let json = try? JSONSerialization.jsonObject(with: settings) as? [String: Any]
    {
      plan = Self.trimmed(json["subscription_tier_display"] as? String)
    }
    guard
      let quota = Self.mapBilling(data, plan: plan, displayName: candidate.displayName, now: now())
    else { throw InfrastructureQuotaFetchError.invalidResponse }
    return quota
  }

  private func get(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Quotio", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return (data, http)
  }

  private func refresh(_ candidate: Candidate) async throws -> Candidate {
    guard let refreshToken = candidate.refreshToken else {
      throw InfrastructureQuotaFetchError.forbidden
    }
    var request = URLRequest(url: refreshURL)
    request.httpMethod = "POST"
    request.httpBody = Data(
      "grant_type=refresh_token&client_id=\(Self.form(candidate.clientID))&refresh_token=\(Self.form(refreshToken))"
        .utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = Self.trimmed(json["access_token"] as? String)
    else { throw InfrastructureQuotaFetchError.invalidResponse }
    let rotated = Self.trimmed(json["refresh_token"] as? String) ?? refreshToken
    let idToken = Self.trimmed(json["id_token"] as? String) ?? candidate.idToken
    let expiry = now().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
    try? await writer.persist(
      path: authPath, entryKey: candidate.entryKey, accessToken: access, refreshToken: rotated,
      idToken: idToken, expiresAt: expiry)
    return Candidate(
      entryKey: candidate.entryKey, accessToken: access, refreshToken: rotated, idToken: idToken,
      clientID: candidate.clientID, expiresAt: expiry)
  }

  private nonisolated static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
  private nonisolated static func clientID(_ key: String) -> String? {
    key.range(of: "::", options: .backwards).flatMap { trimmed(String(key[$0.upperBound...])) }
  }
  private nonisolated static func number(_ value: Any?) -> Double? {
    value is NSNumber ? (value as? NSNumber)?.doubleValue : (value as? String).flatMap(Double.init)
  }
  private nonisolated static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  private nonisolated static func expiry(_ entry: [String: Any], token: String) -> Date? {
    for key in ["expires_at", "expires"] {
      if let value = entry[key] as? String, let date = parseDate(value) { return date }
    }
    guard let exp = Candidate.jwtString(token, claim: "exp").flatMap(Double.init) else {
      let parts = token.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count > 1 else { return nil }
      var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      value += String(repeating: "=", count: (4 - value.count % 4) % 4)
      guard let data = Data(base64Encoded: value),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let exp = json["exp"] as? NSNumber
      else { return nil }
      return Date(timeIntervalSince1970: exp.doubleValue)
    }
    return Date(timeIntervalSince1970: exp)
  }
  private nonisolated static func form(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=")))
      ?? value
  }
  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
