import Foundation
import QuotioApplication
import QuotioDomain

public struct ClaudeQuotaCredential: Equatable, Sendable {
  public let accountKey: String
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?

  public init(
    accountKey: String, accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil
  ) {
    self.accountKey = accountKey
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

public protocol ClaudeQuotaCredentialLoading: Sendable {
  func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential]
  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async
}

extension ClaudeQuotaCredentialLoading {
  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {}
}

public struct LocalClaudeQuotaCredentialLoader: ClaudeQuotaCredentialLoading {
  public static let legacyDirectory = "~/.cli-proxy-api"
  public static let nativePath = "~/.claude/.credentials.json"

  private let environment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] {
    let paths = credentialPaths()
    var seen = Set<String>()
    return paths.compactMap(Self.load(path:)).filter { seen.insert($0.accountKey).inserted }
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    guard let path = credentialPaths().first(where: {
      Self.load(path: $0)?.accountKey == credential.accountKey
    }) else { return }
    Self.persist(refresh, replacing: expectedRefreshToken, path: path)
  }

  private func credentialPaths() -> [String] {
    var paths: [String] = []
    let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let nativeBase =
      configured?.isEmpty == false
      ? configured!
      : NSString(string: "~/.claude").expandingTildeInPath
    paths.append((nativeBase as NSString).appendingPathComponent(".credentials.json"))

    let directory = NSString(string: Self.legacyDirectory).expandingTildeInPath
    let legacy = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    paths.append(
      contentsOf: legacy.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
        .sorted().map { (directory as NSString).appendingPathComponent($0) })
    return paths
  }

  public static func load(path: String) -> ClaudeQuotaCredential? {
    let expanded = NSString(string: path).expandingTildeInPath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
    return load(data: data)
  }

  public static func load(data: Data, fallbackAccountKey: String = "Claude Code")
    -> ClaudeQuotaCredential?
  {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let oauth = json["claudeAiOauth"] as? [String: Any]
    guard
      let access = nonEmpty((json["access_token"] as? String) ?? (oauth?["accessToken"] as? String))
    else { return nil }
    let key =
      nonEmpty((json["email"] as? String) ?? (oauth?["email"] as? String)) ?? fallbackAccountKey
    let refresh = nonEmpty(
      (json["refresh_token"] as? String) ?? (oauth?["refreshToken"] as? String))
    let expiry: Date?
    if let milliseconds = (oauth?["expiresAt"] as? NSNumber)?.doubleValue {
      expiry = Date(timeIntervalSince1970: milliseconds / 1_000)
    } else {
      expiry = (json["expired"] as? String).flatMap(parseDate)
    }
    return ClaudeQuotaCredential(
      accountKey: key, accessToken: access, refreshToken: refresh, expiresAt: expiry)
  }

  static func updatedData(
    _ data: Data,
    refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String
  ) -> Data? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if var oauth = json["claudeAiOauth"] as? [String: Any] {
      guard oauth["refreshToken"] as? String == expectedRefreshToken else { return nil }
      oauth["accessToken"] = refresh.accessToken
      oauth["refreshToken"] = refresh.refreshToken ?? expectedRefreshToken
      if let expiresAt = refresh.expiresAt {
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1_000)
      }
      json["claudeAiOauth"] = oauth
    } else {
      guard json["refresh_token"] as? String == expectedRefreshToken else { return nil }
      json["access_token"] = refresh.accessToken
      json["refresh_token"] = refresh.refreshToken ?? expectedRefreshToken
      json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
      if let expiresAt = refresh.expiresAt {
        json["expired"] = ISO8601DateFormatter().string(from: expiresAt)
      }
    }
    return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  }

  private static func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    path: String
  ) {
    let url = URL(fileURLWithPath: path)
    guard let current = try? Data(contentsOf: url),
      let updated = updatedData(
        current,
        refresh: refresh,
        replacing: expectedRefreshToken
      )
    else { return }
    try? SecureAtomicFileWriter.write(updated, to: url)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

public actor ClaudeQuotaFetcher: QuotaFetching {
  public nonisolated let provider = QuotaProvider.claude
  public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  public static let refreshScope =
    "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  private let credentials: any ClaudeQuotaCredentialLoading
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date
  private var cache: [String: (quota: ProviderQuota, date: Date)] = [:]

  public init(
    credentials: any ClaudeQuotaCredentialLoading = LocalClaudeQuotaCredentialLoader(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.credentials = credentials
    self.session = session
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let loaded = await credentials.credentials(for: request.mode).filter {
      Self.includes($0.accountKey, scope: request.scope)
    }
    var quotas: [String: ProviderQuota] = [:]
    for credential in loaded {
      if !request.force, let cached = cache[credential.accountKey],
        now().timeIntervalSince(cached.date) < 300
      {
        quotas[credential.accountKey] = cached.quota
        continue
      }
      if let quota = await fetchQuota(credential, mode: request.mode) {
        quotas[credential.accountKey] = quota
        if !quota.isForbidden { cache[credential.accountKey] = (quota, now()) }
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: loaded.isEmpty ? .missing : .present,
      credentialAccountKeys: Set(loaded.map(\.accountKey))
    )
  }

  public nonisolated static func mapUsage(_ data: Data, now: Date = Date()) -> ProviderQuota? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["type"] as? String != "error"
    else { return nil }
    let definitions = [
      ("five_hour", "five-hour-session"),
      ("seven_day", "seven-day-weekly"),
      ("seven_day_sonnet", "seven-day-sonnet"),
      ("seven_day_opus", "seven-day-opus"),
    ]
    var metrics = definitions.compactMap { source, name -> QuotaMetric? in
      guard let value = json[source] as? [String: Any],
        let used = (value["utilization"] as? NSNumber)?.doubleValue
      else { return nil }
      return QuotaMetric(
        name: name, percentage: max(0, min(100, 100 - used)),
        resetTime: value["resets_at"] as? String ?? "")
    }
    if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
      let usedPercent = (extra["utilization"] as? NSNumber)?.doubleValue
    {
      let used = (extra["used_credits"] as? NSNumber)?.doubleValue
      let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue
      metrics.append(
        QuotaMetric(
          name: "extra-usage",
          percentage: max(0, min(100, 100 - usedPercent)),
          resetTime: "",
          presentation: used.flatMap { value in
            limit.map { .progress(used: value, limit: $0, unit: .credits) }
          },
          used: used.map(Int.init),
          limit: limit.map(Int.init)
        ))
    }
    return metrics.isEmpty ? nil : ProviderQuota(models: metrics, lastUpdated: now)
  }

  private func fetchQuota(
    _ original: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async -> ProviderQuota? {
    var credential = original
    var token = credential.accessToken
    if let expiry = credential.expiresAt, expiry.timeIntervalSince(now()) < 60,
      let refresh = credential.refreshToken,
      let refreshed = try? await refreshToken(refresh)
    {
      await credentials.persist(
        refreshed,
        replacing: refresh,
        for: credential,
        mode: mode
      )
      credential = Self.applying(refreshed, to: credential)
      token = refreshed.accessToken
    }
    var response = try? await usage(token: token)
    if let status = response?.1.statusCode, status == 401 || status == 403,
      let latest = await credentials.credentials(for: mode).first(where: {
        $0.accountKey == credential.accountKey
      }),
      let refresh = latest.refreshToken,
      let refreshed = try? await refreshToken(refresh)
    {
      await credentials.persist(
        refreshed,
        replacing: refresh,
        for: latest,
        mode: mode
      )
      response = try? await usage(token: refreshed.accessToken)
    }
    guard let (data, http) = response else { return cache[credential.accountKey]?.quota }
    if http.statusCode == 401 || http.statusCode == 403 {
      return ProviderQuota(lastUpdated: now(), isForbidden: true)
    }
    guard 200...299 ~= http.statusCode else { return cache[credential.accountKey]?.quota }
    return Self.mapUsage(data, now: now()) ?? cache[credential.accountKey]?.quota
  }

  private func usage(token: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: Self.usageURL)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return (data, http)
  }

  private func refreshToken(_ refresh: String) async throws -> QuotaTokenRefresh {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "grant_type": "refresh_token", "refresh_token": refresh,
      "client_id": Self.clientID, "scope": Self.refreshScope,
    ])
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = json["access_token"] as? String
    else { throw InfrastructureQuotaFetchError.forbidden }
    let expiry = (json["expires_in"] as? NSNumber).map {
      now().addingTimeInterval($0.doubleValue)
    }
    return QuotaTokenRefresh(
      accessToken: access,
      refreshToken: json["refresh_token"] as? String,
      expiresAt: expiry
    )
  }

  private nonisolated static func applying(
    _ refresh: QuotaTokenRefresh,
    to credential: ClaudeQuotaCredential
  ) -> ClaudeQuotaCredential {
    ClaudeQuotaCredential(
      accountKey: credential.accountKey,
      accessToken: refresh.accessToken,
      refreshToken: refresh.refreshToken ?? credential.refreshToken,
      expiresAt: refresh.expiresAt ?? credential.expiresAt
    )
  }

  private nonisolated static func includes(_ key: String, scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
