import Darwin
import Foundation
import QuotioApplication
import QuotioDomain

public struct ClaudeQuotaCredential: Equatable, Sendable {
  public let accountKey: String
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?
  /// Whether Quotio may spend this credential's refresh token.
  ///
  /// `false` for credentials the Claude Code CLI or Claude Desktop own: their
  /// refresh tokens are single-use and the CLI marks one it did not spend itself
  /// as dead, so renewing on its behalf can sign the user out. See
  /// ``ClaudeCredentialOwnership``.
  public let allowsRefresh: Bool

  public init(
    accountKey: String, accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
    allowsRefresh: Bool = true
  ) {
    self.accountKey = accountKey
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.allowsRefresh = allowsRefresh
  }

  /// Keeps one credential per account without letting an external read-only
  /// credential hide a refreshable credential owned by Quotio.
  static func uniqueByAccountKey(_ credentials: [Self], now: Date = Date()) -> [Self] {
    let externalRefreshTokens = Set(
      credentials.compactMap { credential in
        credential.allowsRefresh ? nil : credential.refreshToken
      })
    var positions: [String: Int] = [:]
    var result: [Self] = []

    for original in credentials {
      var credential = original
      // A copied CLI token is still CLI-owned, regardless of its file location
      // or account key. Keep it readable for scoped requests, but never refresh it.
      if credential.allowsRefresh, let refreshToken = credential.refreshToken,
        externalRefreshTokens.contains(refreshToken)
      {
        credential = Self(
          accountKey: credential.accountKey,
          accessToken: credential.accessToken,
          refreshToken: credential.refreshToken,
          expiresAt: credential.expiresAt,
          allowsRefresh: false
        )
      }
      if let index = positions[credential.accountKey] {
        let selected = result[index]
        let selectedCanRefresh = selected.allowsRefresh && selected.refreshToken != nil
        let credentialCanRefresh = credential.allowsRefresh && credential.refreshToken != nil
        let selectedIsUsable = selected.expiresAt.map { $0 > now } ?? true
        let credentialIsUsable = credential.expiresAt.map { $0 > now } ?? true
        if (credentialCanRefresh && !selectedCanRefresh)
          || (!selectedCanRefresh && credentialIsUsable && !selectedIsUsable) {
          result[index] = credential
        }
      } else {
        positions[credential.accountKey] = result.count
        result.append(credential)
      }
    }
    return result
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
  private let legacyDirectory: String

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
    self.legacyDirectory = Self.legacyDirectory
  }

  init(environment: [String: String], legacyDirectory: String) {
    self.environment = environment
    self.legacyDirectory = legacyDirectory
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] {
    let credentials = credentialPaths().compactMap { path in
      Self.load(path: path, environment: environment)
    }
    return ClaudeQuotaCredential.uniqueByAccountKey(credentials)
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    for path in credentialPaths() {
      if Self.persist(
        refresh,
        replacing: expectedRefreshToken,
        for: credential,
        path: path,
        environment: environment
      ) {
        return
      }
    }
  }

  private func credentialPaths() -> [String] {
    var paths: [String] = []
    let nativeBase = ClaudeCredentialOwnership.configDirectory(environment: environment)
    paths.append((nativeBase as NSString).appendingPathComponent(".credentials.json"))

    let directory = NSString(string: legacyDirectory).expandingTildeInPath
    let legacy = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    paths.append(
      contentsOf: legacy.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
        .sorted().map { (directory as NSString).appendingPathComponent($0) })
    return paths
  }

  public static func load(path: String, allowsRefresh: Bool = true) -> ClaudeQuotaCredential? {
    guard let file = SecureClaudeCredentialFile(path: path), let data = file.read() else {
      return nil
    }
    return load(data: data, allowsRefresh: allowsRefresh)
  }

  private static func load(
    path: String,
    environment: [String: String]
  ) -> ClaudeQuotaCredential? {
    guard let file = SecureClaudeCredentialFile(path: path), let data = file.read() else {
      return nil
    }
    let ownership = ClaudeCredentialOwnership.forOpenedAuthFile(
      at: file.path, referenceCount: file.referenceCount, environment: environment)
    return load(data: data, allowsRefresh: ownership.allowsRefresh)
  }

  public static func load(
    data: Data, fallbackAccountKey: String = "Claude Code", allowsRefresh: Bool = true
  )
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
      accountKey: key, accessToken: access, refreshToken: refresh, expiresAt: expiry,
      allowsRefresh: allowsRefresh)
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
    for credential: ClaudeQuotaCredential,
    path: String,
    environment: [String: String]
  ) -> Bool {
    guard let file = SecureClaudeCredentialFile(path: path),
      ClaudeCredentialOwnership.forOpenedAuthFile(
        at: file.path, referenceCount: file.referenceCount, environment: environment
      ).allowsRefresh,
      let currentData = file.read(),
      let current = load(data: currentData),
      current.accountKey == credential.accountKey,
      current.refreshToken == expectedRefreshToken,
      let updated = updatedData(
        currentData,
        refresh: refresh,
        replacing: expectedRefreshToken
      )
    else { return false }
    return file.replaceAtomically(with: updated)
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

/// Opens every path component with `O_NOFOLLOW`, then keeps the verified parent
/// directory and file descriptors for the full read/replace operation.
final class SecureClaudeCredentialFile {
  let path: String
  let referenceCount: UInt64

  private let parentDescriptor: Int32
  private let descriptor: Int32
  private let name: String
  private let device: dev_t
  private let inode: ino_t

  init?(path: String) {
    let standardized = ClaudeCredentialOwnership.canonicalPath(path)
    let components = URL(fileURLWithPath: standardized).pathComponents.dropFirst()
    guard let name = components.last, name != ".", name != ".." else { return nil }

    var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { return nil }
    for component in components.dropLast() {
      let next = component.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      Darwin.close(parent)
      guard next >= 0 else { return nil }
      parent = next
    }

    let file = name.withCString {
      Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard file >= 0 else {
      Darwin.close(parent)
      return nil
    }
    var status = stat()
    guard Darwin.fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(file)
      Darwin.close(parent)
      return nil
    }

    self.path = standardized
    self.referenceCount = UInt64(status.st_nlink)
    self.parentDescriptor = parent
    self.descriptor = file
    self.name = name
    self.device = status.st_dev
    self.inode = status.st_ino
  }

  deinit {
    Darwin.close(descriptor)
    Darwin.close(parentDescriptor)
  }

  func read() -> Data? {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    return try? handle.readToEnd() ?? Data()
  }

  func replaceAtomically(with data: Data) -> Bool {
    var current = stat()
    let unchanged = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW) == 0
    }
    guard unchanged, current.st_mode & S_IFMT == S_IFREG,
      current.st_dev == device, current.st_ino == inode
    else { return false }

    let temporaryName = ".\(name).\(UUID().uuidString).tmp"
    let temporary = temporaryName.withCString {
      Darwin.openat(
        parentDescriptor, $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
      )
    }
    guard temporary >= 0 else { return false }

    var succeeded = data.withUnsafeBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return true }
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(temporary, base.advanced(by: written), buffer.count - written)
        if count <= 0 {
          if errno == EINTR { continue }
          return false
        }
        written += count
      }
      return Darwin.fsync(temporary) == 0
    }
    if Darwin.close(temporary) != 0 { succeeded = false }

    if succeeded {
      succeeded = temporaryName.withCString { source in
        name.withCString { destination in
          Darwin.renameat(parentDescriptor, source, parentDescriptor, destination) == 0
        }
      }
    }
    if !succeeded {
      temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
    }
    return succeeded
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

  /// Quota for one Claude credential.
  ///
  /// A credential Quotio does not own is read-only: its refresh token is never
  /// spent and it is never written back. `claude` serializes token refresh behind
  /// a cross-process lock and marks a refresh token it did not spend itself as
  /// dead on `invalid_grant`, so renewing on its behalf can sign the user out of
  /// Claude Code. An expired access token there simply yields no fresh quota
  /// until the CLI renews it itself, which is the correct outcome for an observer.
  private func fetchQuota(
    _ original: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async -> ProviderQuota? {
    var credential = original
    var token = credential.accessToken
    if credential.allowsRefresh, let expiry = credential.expiresAt,
      expiry.timeIntervalSince(now()) < 60,
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
    if credential.allowsRefresh, let status = response?.1.statusCode,
      status == 401 || status == 403,
      let latest = await credentials.credentials(for: mode).first(where: {
        $0.accountKey == credential.accountKey
      }),
      latest.allowsRefresh,
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
      // A credential we may not renew has no re-authentication story in Quotio:
      // the CLI refreshes it on its own schedule. Reporting `isForbidden` would
      // ask the user to sign in to Quotio for a credential Quotio does not
      // manage, so fall back to cached data instead.
      guard credential.allowsRefresh else { return cache[credential.accountKey]?.quota }
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
      expiresAt: refresh.expiresAt ?? credential.expiresAt,
      allowsRefresh: credential.allowsRefresh
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
