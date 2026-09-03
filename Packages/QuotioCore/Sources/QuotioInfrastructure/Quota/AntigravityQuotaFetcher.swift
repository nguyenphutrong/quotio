import Foundation
import QuotioApplication
import QuotioDomain

public struct AntigravityCredential: Equatable, Sendable {
  public enum Origin: Equatable, Sendable {
    case authFile(path: String, originalData: Data)
    case monitor(account: Account)
    case native
  }

  public let accountKey: String
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date?
  public var storedCredential: StoredCredential?
  public let origin: Origin

  public init(
    accountKey: String,
    accessToken: String,
    refreshToken: String? = nil,
    expiresAt: Date? = nil,
    storedCredential: StoredCredential? = nil,
    origin: Origin
  ) {
    self.accountKey = accountKey
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.storedCredential = storedCredential
    self.origin = origin
  }
}

public protocol AntigravityCredentialReading: Sendable {
  func credentials() async -> [AntigravityCredential]
}

public protocol AntigravityCredentialWriting: Sendable {
  func save(_ credential: AntigravityCredential, expiresIn: Int) async
}

public struct LocalAntigravityCredentialStore: AntigravityCredentialReading,
  AntigravityCredentialWriting
{
  private let authDirectory: String

  public init(authDirectory: String = "~/.cli-proxy-api") {
    self.authDirectory = authDirectory
  }

  public func credentials() async -> [AntigravityCredential] {
    let directory = NSString(string: authDirectory).expandingTildeInPath
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
      return []
    }
    return names.sorted().compactMap { name in
      guard name.hasPrefix("antigravity-"), name.hasSuffix(".json") else { return nil }
      let path = (directory as NSString).appendingPathComponent(name)
      let url = URL(fileURLWithPath: path)
      guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
        let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let accessToken = Self.trimmed(json["access_token"] as? String)
      else { return nil }
      let key =
        name
        .replacingOccurrences(of: "antigravity-", with: "")
        .replacingOccurrences(of: ".json", with: "")
        .replacingOccurrences(of: "_", with: ".")
        .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")
      return AntigravityCredential(
        accountKey: key,
        accessToken: accessToken,
        refreshToken: Self.trimmed(json["refresh_token"] as? String),
        expiresAt: Self.date(json["expired"] as? String),
        origin: .authFile(path: path, originalData: data)
      )
    }
  }

  public func save(_ credential: AntigravityCredential, expiresIn: Int) async {
    guard case .authFile(let path, let originalData) = credential.origin,
      (try? Data(contentsOf: URL(fileURLWithPath: path))) == originalData,
      var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any]
    else { return }
    json["access_token"] = credential.accessToken
    json["expired"] = ISO8601DateFormatter().string(from: credential.expiresAt ?? Date())
    json["expires_in"] = expiresIn
    json["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000)
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    else { return }
    try? SecureAtomicFileWriter.write(data, to: URL(fileURLWithPath: path))
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

public actor AntigravityQuotaFetcher: QuotaFetching {
  public nonisolated let provider = QuotaProvider.antigravity

  private let localCredentials: any AntigravityCredentialReading
  private let credentialWriter: any AntigravityCredentialWriting
  private let vault: (any CredentialVault)?
  private let metadata: (any AccountMetadataRepository)?
  private let nativeCredentials: (any AntigravityCredentialReading)?
  private let session: any QuotaHTTPSession
  private let quotaURL: URL
  private let summaryURL: URL
  private let subscriptionURL: URL
  private let tokenURL: URL
  private let now: @Sendable () -> Date
  private let sleep: @Sendable () async -> Void

  private static let clientID =
    "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
  private static let clientSecret = "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"
  private static let userAgent = "antigravity/1.11.3 Darwin/arm64"

  public init(
    localCredentials: any AntigravityCredentialReading = LocalAntigravityCredentialStore(),
    credentialWriter: any AntigravityCredentialWriting = LocalAntigravityCredentialStore(),
    vault: (any CredentialVault)? = nil,
    metadata: (any AccountMetadataRepository)? = nil,
    nativeCredentials: (any AntigravityCredentialReading)? = nil,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    quotaURL: URL = URL(
      string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!,
    summaryURL: URL = URL(
      string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
    subscriptionURL: URL = URL(
      string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
    tokenURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
  ) {
    self.localCredentials = localCredentials
    self.credentialWriter = credentialWriter
    self.vault = vault
    self.metadata = metadata
    self.nativeCredentials = nativeCredentials
    self.session = session
    self.quotaURL = quotaURL
    self.summaryURL = summaryURL
    self.subscriptionURL = subscriptionURL
    self.tokenURL = tokenURL
    self.now = now
    self.sleep = sleep
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    var candidates = await localCredentials.credentials()
    if let nativeCredentials { candidates += await nativeCredentials.credentials() }
    if request.mode == .monitor { candidates += await monitorCredentials() }
    candidates = candidates.filter { Self.includes($0.accountKey, in: request.scope) }

    var quotas: [String: ProviderQuota] = [:]
    var subscriptions: [String: QuotaSubscriptionInfo] = [:]
    for candidate in candidates {
      guard let result = await fetch(candidate) else { continue }
      if quotas[candidate.accountKey] == nil, let quota = result.quota {
        quotas[candidate.accountKey] = quota
      }
      if subscriptions[candidate.accountKey] == nil, let subscription = result.subscription {
        subscriptions[candidate.accountKey] = subscription
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      subscriptions: subscriptions,
      credentialAvailability: candidates.isEmpty ? .missing : .present
    )
  }

  /// Refreshes an Antigravity Google OAuth token using the same client and transport as quota fetching.
  func refreshAccessToken(refreshToken: String) async throws -> QuotaTokenRefresh {
    let credential = AntigravityCredential(
      accountKey: "Antigravity",
      accessToken: "",
      refreshToken: refreshToken,
      origin: .native
    )
    let refreshed = try await refresh(credential, persist: false)
    return QuotaTokenRefresh(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken,
      expiresAt: refreshed.expiresAt
    )
  }

  private func monitorCredentials() async -> [AntigravityCredential] {
    guard let vault else { return [] }
    let disabled = await metadata?.disabledAccountIDs() ?? []
    var result: [AntigravityCredential] = []
    for account in await vault.accounts()
    where account.providerID.rawValue == provider.rawValue && !account.isDisabled
      && !disabled.contains(account.id)
    {
      guard let credential = await vault.credential(for: account.id) else { continue }
      result.append(
        .init(
          accountKey: account.accountKey, accessToken: credential.accessToken,
          refreshToken: credential.refreshToken, expiresAt: credential.expiresAt,
          storedCredential: credential,
          origin: .monitor(account: account)))
    }
    return result
  }

  private func fetch(_ original: AntigravityCredential) async -> (
    quota: ProviderQuota?, subscription: QuotaSubscriptionInfo?
  )? {
    var credential = original
    if shouldRefresh(credential) {
      do {
        credential = try await refresh(credential)
      } catch {
        if case .monitor = credential.origin {
          // Monitor credentials retain the legacy best-effort preflight behavior.
        } else {
          return nil
        }
      }
    }

    var result = await fetchData(token: credential.accessToken)
    if result.quota?.isForbidden == true || result.authorizationFailed {
      if case .monitor(let account) = credential.origin, let vault,
        let latest = await vault.reloadLatest(accountID: account.id)
      {
        credential.accessToken = latest.accessToken
        credential.refreshToken = latest.refreshToken
        credential.expiresAt = latest.expiresAt
        credential.storedCredential = latest
      }
      if let refreshed = try? await refresh(credential) {
        credential = refreshed
        result = await fetchData(token: credential.accessToken)
      }
    }
    return (result.quota, result.subscription)
  }

  private func shouldRefresh(_ credential: AntigravityCredential) -> Bool {
    guard credential.refreshToken != nil else { return false }
    switch credential.origin {
    case .authFile:
      return credential.expiresAt.map { $0 < now() } ?? true
    case .monitor, .native:
      return credential.expiresAt.map { $0.timeIntervalSince(now()) < 300 } ?? false
    }
  }

  private func fetchData(token: String) async -> (
    quota: ProviderQuota?, subscription: QuotaSubscriptionInfo?, authorizationFailed: Bool
  ) {
    let subscription = await fetchSubscription(token: token)
    let project = subscription?.cloudaicompanionProject
    if let models = await fetchSummary(token: token, project: project) {
      return (ProviderQuota(models: models, lastUpdated: now()), subscription, false)
    }
    do {
      return (try await fetchModels(token: token, project: project), subscription, false)
    } catch InfrastructureQuotaFetchError.httpError(let status) where status == 401 || status == 403
    {
      return (nil, subscription, true)
    } catch {
      return (nil, subscription, false)
    }
  }

  private func fetchSubscription(token: String) async -> QuotaSubscriptionInfo? {
    var request = cloudRequest(url: subscriptionURL, token: token)
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "metadata": ["ideType": "ANTIGRAVITY"]
    ])
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode
    else { return nil }
    return try? JSONDecoder().decode(QuotaSubscriptionInfo.self, from: data)
  }

  private func fetchSummary(token: String, project: String?) async -> [QuotaMetric]? {
    let payloads: [[String: Any]] = project.map { [["project": $0], [:]] } ?? [[:]]
    for payload in payloads {
      var request = cloudRequest(url: summaryURL, token: token)
      request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
      guard let (data, response) = try? await session.data(for: request),
        let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
        let models = Self.parseSummary(data), !models.isEmpty
      else { continue }
      return models
    }
    return nil
  }

  private func fetchModels(token: String, project: String?) async throws -> ProviderQuota {
    var request = cloudRequest(url: quotaURL, token: token)
    request.httpBody = try JSONSerialization.data(
      withJSONObject: project.map { ["project": $0] } ?? [:])
    var lastError: Error = InfrastructureQuotaFetchError.invalidResponse
    for attempt in 1...3 {
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw InfrastructureQuotaFetchError.invalidResponse
        }
        if http.statusCode == 403 { return ProviderQuota(lastUpdated: now(), isForbidden: true) }
        guard 200...299 ~= http.statusCode else {
          throw InfrastructureQuotaFetchError.httpError(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = root["models"] as? [String: Any]
        else { throw InfrastructureQuotaFetchError.invalidResponse }
        let metrics = models.compactMap { name, raw -> QuotaMetric? in
          guard name.contains("gemini") || name.contains("claude"),
            let model = raw as? [String: Any], let info = model["quotaInfo"] as? [String: Any]
          else { return nil }
          let remaining = Self.number(info["remainingFraction"]) ?? 0
          return .init(
            name: name, percentage: min(100, max(0, remaining * 100)),
            resetTime: info["resetTime"] as? String ?? "")
        }
        return ProviderQuota(models: metrics, lastUpdated: now())
      } catch {
        lastError = error
        if attempt < 3 { await sleep() }
      }
    }
    throw lastError
  }

  private func refresh(
    _ credential: AntigravityCredential,
    persist: Bool = true
  ) async throws -> AntigravityCredential {
    guard let refreshToken = credential.refreshToken else {
      throw InfrastructureQuotaFetchError.forbidden
    }
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      "client_id=\(Self.form(Self.clientID))&client_secret=\(Self.form(Self.clientSecret))&refresh_token=\(Self.form(refreshToken))&grant_type=refresh_token"
        .utf8)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = json["access_token"] as? String
    else { throw InfrastructureQuotaFetchError.invalidResponse }
    let expiresIn = (json["expires_in"] as? NSNumber)?.intValue ?? 3600
    var updated = credential
    updated.accessToken = access
    updated.expiresAt = now().addingTimeInterval(TimeInterval(expiresIn))
    guard persist else { return updated }
    switch credential.origin {
    case .monitor(let account):
      if let vault {
        var stored =
          credential.storedCredential
          ?? StoredCredential(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            idToken: nil,
            accountID: account.id,
            expiresAt: credential.expiresAt,
            extra: [:]
          )
        stored.accessToken = access
        stored.expiresAt = updated.expiresAt
        try? await vault.save(stored, metadata: account)
      }
    case .authFile:
      await credentialWriter.save(updated, expiresIn: expiresIn)
    case .native:
      await credentialWriter.save(updated, expiresIn: expiresIn)
    }
    return updated
  }

  private func cloudRequest(url: URL, token: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  public nonisolated static func parseSummary(_ data: Data) -> [QuotaMetric]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let groups =
      (root["groups"] as? [[String: Any]])
      ?? ((root["response"] as? [String: Any])?["groups"] as? [[String: Any]])
      ?? ((root["summary"] as? [String: Any])?["groups"] as? [[String: Any]])
    guard let groups else { return nil }
    var metrics: [QuotaMetric] = []
    for group in groups {
      guard let name = string(group["displayName"] ?? group["name"]),
        let groupID = groupID(name), let buckets = group["buckets"] as? [[String: Any]]
      else { continue }
      for bucket in buckets {
        let label = [
          bucket["bucketId"], bucket["id"], bucket["displayName"], bucket["name"], bucket["window"],
        ]
        .compactMap(string).joined(separator: " ")
        guard bool(bucket["disabled"]) != true, let period = period(label),
          let fraction = fraction(bucket)
        else { continue }
        let reset =
          string(
            bucket["resetTime"] ?? bucket["reset_time"] ?? bucket["resetAt"] ?? bucket["reset_at"])
          ?? ""
        metrics.append(
          .init(
            name: "antigravity-\(groupID)-\(period)", percentage: min(100, max(0, fraction * 100)),
            resetTime: reset))
      }
    }
    let order = [
      "antigravity-gemini-session", "antigravity-gemini-weekly", "antigravity-claude-gpt-session",
      "antigravity-claude-gpt-weekly",
    ]
    var seen = Set<String>()
    return metrics.filter { seen.insert($0.name).inserted }.sorted {
      (order.firstIndex(of: $0.name) ?? order.count)
        < (order.firstIndex(of: $1.name) ?? order.count)
    }
  }

  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value
    case .importedAccounts(let values): values.contains(key)
    }
  }
  private nonisolated static func string(_ value: Any?) -> String? {
    let raw = (value as? String) ?? (value as? NSNumber)?.stringValue
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
  private nonisolated static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
  }
  private nonisolated static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    guard let value = string(value)?.lowercased() else { return nil }
    return ["true", "1"].contains(value) ? true : ["false", "0"].contains(value) ? false : nil
  }
  private nonisolated static func groupID(_ value: String) -> String? {
    let value = value.lowercased()
    return value.contains("gemini")
      ? "gemini" : (value.contains("claude") || value.contains("gpt")) ? "claude-gpt" : nil
  }
  private nonisolated static func period(_ value: String) -> String? {
    let value = value.lowercased()
    return value.contains("week") || value.contains("7d") || value.contains("seven")
      ? "weekly"
      : value.contains("session") || value.contains("5") || value.contains("hour") ? "session" : nil
  }
  private nonisolated static func fraction(_ bucket: [String: Any]) -> Double? {
    if let value = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) {
      return value
    }
    guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
    if let value = number(remaining["remainingFraction"] ?? remaining["remaining_fraction"]) {
      return value
    }
    return string(remaining["case"]) == "remainingFraction" ? number(remaining["value"]) : nil
  }
  private nonisolated static func form(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=")))
      ?? value
  }
}
