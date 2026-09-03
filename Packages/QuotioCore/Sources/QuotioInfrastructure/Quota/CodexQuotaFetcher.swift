import Foundation
import QuotioApplication
import QuotioDomain

public struct CodexQuotaCredential: Equatable, Sendable {
  public let accountKey: String
  public let aliases: Set<String>
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let accountID: String?

  public init(
    accountKey: String, aliases: Set<String> = [], accessToken: String,
    refreshToken: String? = nil, idToken: String? = nil,
    accountID: String? = nil
  ) {
    self.accountKey = accountKey
    self.aliases = aliases
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.accountID = accountID
  }
}

public protocol CodexQuotaCredentialLoading: Sendable {
  func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential]
  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async
}

extension CodexQuotaCredentialLoading {
  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async {}
}

public struct LocalCodexQuotaCredentialLoader: CodexQuotaCredentialLoading {
  private let environment: [String: String]
  private let legacyDirectoryOverride: String?
  private let nativePathsOverride: [String]?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
    self.legacyDirectoryOverride = nil
    self.nativePathsOverride = nil
  }

  init(legacyDirectory: String, nativePaths: [String]) {
    self.environment = [:]
    self.legacyDirectoryOverride = legacyDirectory
    self.nativePathsOverride = nativePaths
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential] {
    credentialSources(for: mode).map(\.credential)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    for source in credentialSources(for: mode) where source.credential.accountKey == credential.accountKey
    {
      guard let data = Self.updatedData(
        path: source.path,
        isNative: source.isNative,
        refresh: refresh,
        replacing: expectedRefreshToken
      ) else { return }
      try? SecureAtomicFileWriter.write(data, to: URL(fileURLWithPath: source.path))
      return
    }
  }

  private func credentialSources(for mode: QuotaOperatingMode) -> [(
    path: String, isNative: Bool, credential: CodexQuotaCredential
  )] {
    let legacyDirectory = legacyDirectoryOverride
      ?? NSString(string: "~/.cli-proxy-api").expandingTildeInPath
    let legacyFiles =
      ((try? FileManager.default.contentsOfDirectory(atPath: legacyDirectory)) ?? [])
      .filter { $0.hasPrefix("codex-") && $0.hasSuffix(".json") }.sorted()
    var values = legacyFiles.compactMap { filename -> (
      path: String, isNative: Bool, credential: CodexQuotaCredential
    )? in
      let path = (legacyDirectory as NSString).appendingPathComponent(filename)
      return Self.loadLegacy(path: path, filename: filename).map { (path, false, $0) }
    }
    guard mode == .monitor else { return values }

    let paths: [String]
    if let nativePathsOverride {
      paths = nativePathsOverride
    } else {
      var defaults: [String] = []
      if let home = environment["CODEX_HOME"], !home.isEmpty {
        defaults.append((home as NSString).appendingPathComponent("auth.json"))
      }
      defaults.append(NSString(string: "~/.config/codex/auth.json").expandingTildeInPath)
      defaults.append(NSString(string: "~/.codex/auth.json").expandingTildeInPath)
      paths = defaults
    }
    let aliases = Self.uniqueLegacyAliases(values.map(\.credential))
    for path in paths {
      guard var credential = Self.loadNative(path: path) else { continue }
      if let accountID = credential.accountID, let alias = aliases[accountID] {
        let nativeAccountKey = credential.accountKey
        credential = CodexQuotaCredential(
          accountKey: alias, aliases: [nativeAccountKey], accessToken: credential.accessToken,
          refreshToken: credential.refreshToken, idToken: credential.idToken, accountID: accountID)
      }
      if let existing = values.firstIndex(where: { $0.credential.accountKey == credential.accountKey }) {
        if !values[existing].isNative {
          values[existing] = (path, true, credential)
        }
      } else {
        values.append((path, true, credential))
      }
    }
    return values
  }

  public static func loadLegacy(path: String, filename: String) -> CodexQuotaCredential? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let key = String(filename.dropFirst("codex-".count).dropLast(".json".count))
    return loadLegacy(data: data, accountKey: key)
  }

  public static func loadLegacy(data: Data, accountKey: String) -> CodexQuotaCredential? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = nonEmpty(json["access_token"] as? String)
    else { return nil }
    let idToken = nonEmpty(json["id_token"] as? String)
    return CodexQuotaCredential(
      accountKey: accountKey, accessToken: access,
      refreshToken: nonEmpty(json["refresh_token"] as? String), idToken: idToken,
      accountID: nonEmpty(json["account_id"] as? String) ?? claims(idToken)["accountID"])
  }

  public static func loadNative(path: String) -> CodexQuotaCredential? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return loadNative(data: data)
  }

  public static func loadNative(data: Data, fallbackAccountKey: String = "Codex User")
    -> CodexQuotaCredential?
  {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = json["tokens"] as? [String: Any],
      let access = nonEmpty(tokens["access_token"] as? String)
    else { return nil }
    let idToken = nonEmpty(tokens["id_token"] as? String)
    let decoded = claims(idToken)
    let accountID = nonEmpty(tokens["account_id"] as? String) ?? decoded["accountID"]
    return CodexQuotaCredential(
      accountKey: decoded["email"] ?? accountID ?? fallbackAccountKey, accessToken: access,
      refreshToken: nonEmpty(tokens["refresh_token"] as? String), idToken: idToken,
      accountID: accountID)
  }

  static func updatedData(
    _ data: Data,
    isNative: Bool,
    refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String
  ) -> Data? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if isNative {
      guard var tokens = json["tokens"] as? [String: Any],
        tokens["refresh_token"] as? String == expectedRefreshToken
      else { return nil }
      tokens["access_token"] = refresh.accessToken
      tokens["refresh_token"] = refresh.refreshToken ?? expectedRefreshToken
      if let idToken = refresh.idToken { tokens["id_token"] = idToken }
      json["tokens"] = tokens
      json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    } else {
      guard json["refresh_token"] as? String == expectedRefreshToken else { return nil }
      json["access_token"] = refresh.accessToken
      json["refresh_token"] = refresh.refreshToken ?? expectedRefreshToken
      if let idToken = refresh.idToken { json["id_token"] = idToken }
      if let expiresAt = refresh.expiresAt {
        json["expired"] = ISO8601DateFormatter().string(from: expiresAt)
      }
    }
    return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  }

  private static func updatedData(
    path: String,
    isNative: Bool,
    refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String
  ) -> Data? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return updatedData(
      data,
      isNative: isNative,
      refresh: refresh,
      replacing: expectedRefreshToken
    )
  }

  public static func uniqueLegacyAliases(_ credentials: [CodexQuotaCredential]) -> [String: String]
  {
    let grouped = Dictionary(
      grouping: credentials.compactMap { value in value.accountID.map { ($0, value.accountKey) } },
      by: \.0)
    return grouped.compactMapValues { entries in
      let keys = Set(entries.map(\.1))
      return keys.count == 1 ? keys.first : nil
    }
  }

  static func claims(_ token: String?) -> [String: String] {
    guard let token else { return [:] }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return [:] }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    let auth = json["https://api.openai.com/auth"] as? [String: Any]
    return [
      "email": nonEmpty(json["email"] as? String),
      "plan": nonEmpty(auth?["chatgpt_plan_type"] as? String),
      "accountID": nonEmpty(auth?["chatgpt_account_id"] as? String),
    ].compactMapValues { $0 }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

public actor CodexQuotaFetcher: QuotaFetching {
  public nonisolated let provider = QuotaProvider.codex
  public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
  public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
  public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private let credentials: any CodexQuotaCredentialLoading
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date

  public init(
    credentials: any CodexQuotaCredentialLoading = LocalCodexQuotaCredentialLoader(),
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
      if let quota = try? await fetchQuota(credential, mode: request.mode) {
        quotas[credential.accountKey] = quota
      }
    }
    let aliases = loaded.reduce(into: [String: String]()) { result, credential in
      for alias in credential.aliases where alias != credential.accountKey {
        result[alias] = credential.accountKey
      }
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: loaded.isEmpty ? .missing : .present,
      accountAliases: aliases
    )
  }

  public nonisolated static func mapUsage(
    _ data: Data, planFallback: String? = nil, now: Date = Date()
  ) throws -> ProviderQuota {
    let response = try JSONDecoder().decode(Response.self, from: data)
    var metrics: [QuotaMetric] = []
    var kinds = Set<String>()
    for (window, fallback) in [
      (response.rateLimit?.primary, "codex-session"),
      (response.rateLimit?.secondary, "codex-weekly"),
    ] {
      guard let window else { continue }
      let name =
        window.windowSeconds.map {
          $0 >= 518_400 ? "codex-weekly" : ($0 <= 86_400 ? "codex-session" : fallback)
        }
        ?? (window.resetAfter.map { $0 > 86_400 ? "codex-weekly" : fallback } ?? fallback)
      guard kinds.insert(name).inserted else { continue }
      metrics.append(
        .init(
          name: name, percentage: Double(100 - window.usedPercent),
          resetTime: window.resetAt.map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
          } ?? ""))
    }
    for limit in response.additional ?? [] {
      let spark = [limit.name, limit.feature].compactMap { $0?.lowercased() }.contains {
        $0.contains("spark")
      }
      if spark {
        for (window, fallback) in [
          (limit.rateLimit?.primary, "codex-spark"),
          (limit.rateLimit?.secondary, "codex-spark-weekly"),
        ] {
          guard let window else { continue }
          let name =
            window.windowSeconds.map { $0 >= 518_400 ? "codex-spark-weekly" : "codex-spark" }
            ?? fallback
          guard kinds.insert(name).inserted else { continue }
          metrics.append(
            .init(
              name: name, percentage: Double(100 - window.usedPercent),
              resetTime: window.resetAt.map {
                ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
              } ?? ""))
        }
      } else if let source = nonEmpty(limit.feature) ?? nonEmpty(limit.name),
        let window = limit.rateLimit?.primary ?? limit.rateLimit?.secondary
      {
        let slug = source.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }
          .joined().split(separator: "-").joined(separator: "-")
        let name = "codex-" + slug
        guard kinds.insert(name).inserted else { continue }
        metrics.append(
          .init(
            name: name, percentage: Double(100 - window.usedPercent),
            resetTime: window.resetAt.map {
              ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
            } ?? ""))
      }
    }
    return ProviderQuota(
      models: metrics, lastUpdated: now, isForbidden: response.rateLimit?.reached ?? false,
      planType: response.plan ?? planFallback)
  }

  private func fetchQuota(
    _ credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async throws -> ProviderQuota {
    do {
      return try await requestQuota(token: credential.accessToken, credential: credential)
    } catch InfrastructureQuotaFetchError.httpError(let status) where status == 401 || status == 403
    {
      let latest = await credentials.credentials(for: mode).first(where: {
        $0.accountKey == credential.accountKey
      }) ?? credential
      guard let refreshToken = latest.refreshToken else {
        throw InfrastructureQuotaFetchError.httpError(status)
      }
      let refreshed = try await refresh(refreshToken)
      await credentials.persist(
        refreshed,
        replacing: refreshToken,
        for: latest,
        mode: mode
      )
      return try await requestQuota(token: refreshed.accessToken, credential: latest)
    }
  }

  private func requestQuota(token: String, credential: CodexQuotaCredential) async throws
    -> ProviderQuota
  {
    var request = URLRequest(url: Self.usageURL)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let accountID = credential.accountID, !accountID.isEmpty {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    guard 200...299 ~= http.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(http.statusCode)
    }
    return try Self.mapUsage(
      data, planFallback: LocalCodexQuotaCredentialLoader.claims(credential.idToken)["plan"],
      now: now())
  }

  private func refresh(_ refreshToken: String) async throws -> QuotaTokenRefresh {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      [
        "grant_type=refresh_token",
        "client_id=" + Self.form(Self.clientID),
        "refresh_token=" + Self.form(refreshToken),
      ].joined(separator: "&").utf8)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = json["access_token"] as? String
    else {
      throw InfrastructureQuotaFetchError.forbidden
    }
    let expiry = (json["expires_in"] as? NSNumber).map {
      now().addingTimeInterval($0.doubleValue)
    }
    return QuotaTokenRefresh(
      accessToken: accessToken,
      refreshToken: json["refresh_token"] as? String,
      idToken: json["id_token"] as? String,
      expiresAt: expiry
    )
  }

  private nonisolated static func form(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private nonisolated static func includes(_ key: String, scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }

  private nonisolated static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private struct Response: Decodable {
    let plan: String?
    let rateLimit: Limit?
    let additional: [Additional]?
    enum CodingKeys: String, CodingKey {
      case plan = "plan_type"
      case rateLimit = "rate_limit"
      case additional = "additional_rate_limits"
    }
  }
  private struct Limit: Decodable {
    let reached: Bool?
    let primary: Window?
    let secondary: Window?
    enum CodingKeys: String, CodingKey {
      case reached = "limit_reached"
      case primary = "primary_window"
      case secondary = "secondary_window"
    }
  }
  private struct Additional: Decodable {
    let name: String?
    let feature: String?
    let rateLimit: Limit?
    enum CodingKeys: String, CodingKey {
      case name = "limit_name"
      case feature = "metered_feature"
      case rateLimit = "rate_limit"
    }
  }
  private struct Window: Decodable {
    let usedPercent: Int
    let resetAt: Int?
    let resetAfter: Int?
    let windowSeconds: Int?
    enum CodingKeys: String, CodingKey {
      case usedPercent = "used_percent"
      case resetAt = "reset_at"
      case resetAfter = "reset_after_seconds"
      case windowSeconds = "limit_window_seconds"
    }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      usedPercent = max(0, min(100, try Self.number(values, .usedPercent)))
      resetAt = try? Self.number(values, .resetAt)
      resetAfter = try? Self.number(values, .resetAfter)
      windowSeconds = try? Self.number(values, .windowSeconds)
    }
    private static func number(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys)
      throws -> Int
    {
      if let value = try? values.decode(Int.self, forKey: key) { return value }
      if let value = try? values.decode(Double.self, forKey: key) { return Int(value.rounded()) }
      if let value = try? values.decode(String.self, forKey: key), let number = Double(value) {
        return Int(number.rounded())
      }
      throw DecodingError.dataCorruptedError(
        forKey: key, in: values, debugDescription: "Expected number")
    }
  }
}
