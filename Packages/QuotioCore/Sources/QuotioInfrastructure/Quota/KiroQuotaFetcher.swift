import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain

public struct KiroQuotaCredential: Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date?
  public var clientID: String?
  public var clientSecret: String?
  public var authMethod: String
  public var profileARN: String?
  public var region: String?
  public let accountKey: String
  public let filePath: String?

  public init(
    accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
    clientID: String? = nil, clientSecret: String? = nil, authMethod: String = "IdC",
    profileARN: String? = nil, region: String? = nil, accountKey: String, filePath: String? = nil
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.authMethod = authMethod
    self.profileARN = profileARN
    self.region = region
    self.accountKey = accountKey
    self.filePath = filePath
  }
}

public protocol KiroQuotaCredentialSourcing: Sendable {
  func credentials() async -> [KiroQuotaCredential]
  func reload(path: String) async -> KiroQuotaCredential?
  func persist(
    path: String, expectedRefreshToken: String, accessToken: String, refreshToken: String?,
    expiresAt: Date) async
}

public actor LocalKiroQuotaCredentialSource: KiroQuotaCredentialSourcing {
  private let homeDirectory: String
  public init(homeDirectory: String = NSHomeDirectory()) { self.homeDirectory = homeDirectory }

  public func credentials() -> [KiroQuotaCredential] {
    let home = URL(fileURLWithPath: homeDirectory)
    var urls = [home.appendingPathComponent(".aws/sso/cache/kiro-auth-token.json")]
    let proxyDirectory = home.appendingPathComponent(".cli-proxy-api")
    urls +=
      ((try? FileManager.default.contentsOfDirectory(
        at: proxyDirectory, includingPropertiesForKeys: nil)) ?? []).filter {
        guard $0.pathExtension == "json" else { return false }
        if $0.lastPathComponent.hasPrefix("kiro-") { return true }
        guard let data = FileManager.default.contents(atPath: $0.path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["type"] as? String)?.lowercased() == "kiro"
      }
    var seen = Set<String>()
    return urls.compactMap { seen.insert($0.path).inserted ? decode(path: $0.path) : nil }
  }

  public func reload(path: String) -> KiroQuotaCredential? { decode(path: path) }

  public func persist(
    path: String, expectedRefreshToken: String, accessToken: String, refreshToken: String?,
    expiresAt: Date
  ) {
    guard let data = FileManager.default.contents(atPath: path),
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      ((object["refresh_token"] as? String) ?? (object["refreshToken"] as? String))
        == expectedRefreshToken
    else { return }
    let isNative = path.contains("/.aws/sso/cache/")
    object[isNative ? "accessToken" : "access_token"] = accessToken
    if let refreshToken { object[isNative ? "refreshToken" : "refresh_token"] = refreshToken }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    object[isNative ? "expiresAt" : "expires_at"] = formatter.string(from: expiresAt)
    if !isNative { object["last_refresh"] = formatter.string(from: Date()) }
    guard
      let updated = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? SecureAtomicFileWriter.write(updated, to: URL(fileURLWithPath: path))
  }

  private func decode(path: String) -> KiroQuotaCredential? {
    guard let data = FileManager.default.contents(atPath: path),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = string(object, "access_token", "accessToken")
    else { return nil }
    let profile = string(object, "profile_arn", "profileArn")
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let providerKey = string(object, "provider").map { "Kiro (\($0))" }
    let key = string(object, "email") ?? providerKey ?? profile ?? filename
    return .init(
      accessToken: access, refreshToken: string(object, "refresh_token", "refreshToken"),
      expiresAt: Self.date(
        string(object, "expires_at", "expiresAt", "expiry", "expired"),
        number: object["expired"] as? NSNumber), clientID: string(object, "client_id", "clientId"),
      clientSecret: string(object, "client_secret", "clientSecret"),
      authMethod: string(object, "auth_method", "authMethod") ?? "IdC", profileARN: profile,
      region: string(object, "region"), accountKey: key, filePath: path)
  }

  private func string(_ object: [String: Any], _ keys: String...) -> String? {
    for key in keys {
      if let value = object[key] as? String,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return value
      }
    }
    return nil
  }

  private static func date(_ value: String?, number: NSNumber? = nil) -> Date? {
    if let number { return Date(timeIntervalSince1970: number.doubleValue) }
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

public actor KiroQuotaFetcher: QuotaFetching {
  public nonisolated let provider = QuotaProvider.kiro
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let credentials: any KiroQuotaCredentialSourcing
  private let session: any QuotaHTTPSession
  private let now: @Sendable () -> Date
  private let machineSeed: @Sendable (KiroQuotaCredential) -> String

  public init(
    vault: any CredentialVault, metadata: any AccountMetadataRepository,
    credentials: any KiroQuotaCredentialSourcing = LocalKiroQuotaCredentialSource(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 20)),
    now: @escaping @Sendable () -> Date = Date.init,
    machineSeed: @escaping @Sendable (KiroQuotaCredential) -> String = {
      $0.clientID ?? $0.refreshToken ?? "Quotio"
    }
  ) {
    self.vault = vault
    self.metadata = metadata
    self.credentials = credentials
    self.session = session
    self.now = now
    self.machineSeed = machineSeed
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    var candidates: [(KiroQuotaCredential, Account?)] = []
    if request.mode == .monitor {
      let disabled = await metadata.disabledAccountIDs()
      for account in await vault.accounts()
      where account.providerID.rawValue == provider.rawValue && !disabled.contains(account.id) {
        guard let stored = await vault.credential(for: account.id), !stored.accessToken.isEmpty else {
          continue
        }
        candidates.append((Self.from(stored, key: account.accountKey), account))
      }
    }
    candidates += await credentials.credentials().map { ($0, nil) }
    let applicable = candidates.filter { Self.includes($0.0.accountKey, request.scope) }
    var quotas: [String: ProviderQuota] = [:]
    var seen = Set<String>()
    for (credential, account) in applicable where seen.insert(credential.accountKey).inserted {
      if let quota = await fetchOne(credential, account: account) {
        quotas[credential.accountKey] = quota
      }
    }
    return .init(quotas: quotas, credentialAvailability: applicable.isEmpty ? .missing : .present)
  }

  public func refreshAllLocalTokensIfNeeded() async -> Int {
    var refreshedCount = 0
    for credential in await credentials.credentials()
    where credential.expiresAt.map({ $0.timeIntervalSince(now()) < 300 }) == true {
      if await refresh(credential, account: nil) != nil {
        refreshedCount += 1
      }
    }
    return refreshedCount
  }

  public func authenticatedAccountIdentity(
    accessToken: String,
    expiresAt: Date,
    clientID: String,
    clientSecret: String,
    region: String
  ) async -> String? {
    let credential = KiroQuotaCredential(
      accessToken: accessToken,
      expiresAt: expiresAt,
      clientID: clientID,
      clientSecret: clientSecret,
      region: region,
      accountKey: ""
    )
    let response = await usage(credential)
    guard response.status == 200,
      let data = response.data,
      let decoded = try? JSONDecoder().decode(KiroUsageResponse.self, from: data),
      let user = decoded.userInfo
    else { return nil }
    let identities: [String?] = [user.email, user.userId]
    return identities.compactMap { value -> String? in
      guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      else { return nil }
      return value
    }.first
  }

  private func fetchOne(_ original: KiroQuotaCredential, account: Account?) async -> ProviderQuota?
  {
    var credential = original
    var refreshed = false
    if credential.expiresAt.map({ $0.timeIntervalSince(now()) < 300 }) == true {
      guard let value = await refresh(credential, account: account) else {
        return ProviderQuota(
          lastUpdated: now(), isForbidden: true, planType: "Expired",
          tokenExpiresAt: credential.expiresAt)
      }
      credential = value
      refreshed = true
    }
    var response = await usage(credential)
    if (response.status == 401 || response.status == 403) && !refreshed {
      if let path = credential.filePath, let latest = await credentials.reload(path: path) {
        credential = latest
      }
      if let value = await refresh(credential, account: account) {
        credential = value
        response = await usage(value)
      }
    }
    if response.status == 401 || response.status == 403 {
      return ProviderQuota(
        lastUpdated: now(), isForbidden: true, planType: "Unauthorized",
        tokenExpiresAt: credential.expiresAt)
    }
    guard response.status == 200, let data = response.data,
      let decoded = try? JSONDecoder().decode(KiroUsageResponse.self, from: data)
    else { return nil }
    return Self.map(decoded, expiry: credential.expiresAt, now: now())
  }

  private func usage(_ credential: KiroQuotaCredential) async -> (data: Data?, status: Int?) {
    let region = Self.region(profileARN: credential.profileARN) ?? credential.region ?? "us-east-1"
    var components = URLComponents(string: "https://q.\(region).amazonaws.com/getUsageLimits")!
    components.queryItems = [
      .init(name: "origin", value: "AI_EDITOR"),
      .init(name: "resourceType", value: "AGENTIC_REQUEST"),
    ]
    if let arn = credential.profileARN, !arn.isEmpty {
      components.queryItems?.append(.init(name: "profileArn", value: arn))
    }
    var request = URLRequest(url: components.url!)
    let machineID = SHA256.hash(data: Data(machineSeed(credential).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("q.\(region).amazonaws.com", forHTTPHeaderField: "Host")
    request.setValue(
      "aws-sdk-js/1.0.0 ua/2.1 os/darwin lang/js md/nodejs#22.21.1 api/codewhispererruntime#1.0.0 m/N,E KiroIDE-0.10.32-\(machineID)",
      forHTTPHeaderField: "User-Agent")
    request.setValue(
      "aws-sdk-js/1.0.0 KiroIDE-0.10.32-\(machineID)", forHTTPHeaderField: "x-amz-user-agent")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "amz-sdk-invocation-id")
    request.setValue("attempt=1; max=1", forHTTPHeaderField: "amz-sdk-request")
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse
    else { return (nil, nil) }
    return (data, http.statusCode)
  }

  private func refresh(_ credential: KiroQuotaCredential, account: Account?) async
    -> KiroQuotaCredential?
  {
    guard let refreshToken = credential.refreshToken else { return nil }
    let region = credential.region ?? "us-east-1"
    let social = credential.authMethod.lowercased() == "social"
    let endpoint =
      social
      ? "https://prod.\(region).auth.desktop.kiro.dev/refreshToken"
      : "https://oidc.\(region).amazonaws.com/token"
    guard let url = URL(string: endpoint) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body = ["refreshToken": refreshToken]
    if !social {
      guard let clientID = credential.clientID, let clientSecret = credential.clientSecret else {
        return nil
      }
      body.merge(["clientId": clientID, "clientSecret": clientSecret, "grantType": "refresh_token"])
      { _, new in new }
      request.setValue("oidc.\(region).amazonaws.com", forHTTPHeaderField: "Host")
      request.setValue("keep-alive", forHTTPHeaderField: "Connection")
      request.setValue(
        "aws-sdk-js/3.980.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.980.0 m/E KiroIDE",
        forHTTPHeaderField: "x-amz-user-agent")
      request.setValue("*/*", forHTTPHeaderField: "Accept")
      request.setValue("*", forHTTPHeaderField: "Accept-Language")
      request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
      request.setValue("node", forHTTPHeaderField: "User-Agent")
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard let (data, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let token = try? JSONDecoder().decode(KiroTokenResponse.self, from: data)
    else { return nil }
    let expiry = now().addingTimeInterval(TimeInterval(token.expiresIn))
    var updated = credential
    updated.accessToken = token.accessToken
    updated.refreshToken = token.refreshToken ?? refreshToken
    updated.expiresAt = expiry
    if let account {
      let stored = StoredCredential(
        accessToken: updated.accessToken, refreshToken: updated.refreshToken, idToken: nil,
        accountID: nil, expiresAt: expiry, extra: Self.extra(updated))
      try? await vault.save(stored, metadata: account)
    }
    if let path = credential.filePath {
      await credentials.persist(
        path: path, expectedRefreshToken: refreshToken, accessToken: updated.accessToken,
        refreshToken: token.refreshToken, expiresAt: expiry)
    }
    return updated
  }

  private nonisolated static func from(_ value: StoredCredential, key: String)
    -> KiroQuotaCredential
  {
    .init(
      accessToken: value.accessToken, refreshToken: value.refreshToken, expiresAt: value.expiresAt,
      clientID: value.extra["clientId"], clientSecret: value.extra["clientSecret"],
      authMethod: value.extra["authMethod"] ?? "IdC", profileARN: value.extra["profileArn"],
      region: value.extra["region"], accountKey: key)
  }
  private nonisolated static func extra(_ value: KiroQuotaCredential) -> [String: String] {
    var result: [String: String] = [:]
    if let value = value.clientID { result["clientId"] = value }
    if let value = value.clientSecret { result["clientSecret"] = value }
    result["authMethod"] = value.authMethod
    if let value = value.profileARN { result["profileArn"] = value }
    if let value = value.region { result["region"] = value }
    return result
  }
  private nonisolated static func includes(_ key: String, _ scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value
    case .importedAccounts(let values): values.contains(key)
    }
  }
  private nonisolated static func region(profileARN: String?) -> String? {
    guard let parts = profileARN?.split(separator: ":"), parts.count >= 6, parts[0] == "arn",
      parts[2] == "codewhisperer", parts[3].contains("-")
    else { return nil }
    return String(parts[3])
  }
  private nonisolated static func map(_ response: KiroUsageResponse, expiry: Date?, now: Date)
    -> ProviderQuota
  {
    let commonReset =
      response.nextDateReset.map { Date(timeIntervalSince1970: $0).ISO8601Format() } ?? ""
    var metrics: [QuotaMetric] = []
    for item in response.usageBreakdownList ?? [] {
      let name = item.resourceType ?? item.displayName ?? "kiro-standard"
      if item.freeTrialInfo?.freeTrialStatus == "ACTIVE", let trial = item.freeTrialInfo {
        let used = trial.currentUsageWithPrecision ?? trial.currentUsage ?? 0
        let limit = trial.usageLimitWithPrecision ?? trial.usageLimit ?? 0
        let reset =
          trial.freeTrialExpiry.map { Date(timeIntervalSince1970: $0).ISO8601Format() }
          ?? commonReset
        metrics.append(
          .init(
            name: "kiro-bonus-\(name)", percentage: percent(used, limit), resetTime: reset,
            used: Int(used), limit: Int(limit), remaining: Int(max(0, limit - used))))
      }
      let used = item.currentUsageWithPrecision ?? item.currentUsage ?? 0
      let limit = item.usageLimitWithPrecision ?? item.usageLimit ?? 0
      if limit > 0 {
        metrics.append(
          .init(
            name: "kiro-\(name)", percentage: percent(used, limit),
            resetTime: item.nextDateReset.map { Date(timeIntervalSince1970: $0).ISO8601Format() }
              ?? commonReset, used: Int(used), limit: Int(limit),
            remaining: Int(max(0, limit - used))))
      }
    }
    if metrics.isEmpty {
      metrics.append(.init(name: "kiro-standard", percentage: 100, resetTime: commonReset))
    }
    return .init(
      models: metrics, lastUpdated: now,
      planType: response.subscriptionInfo?.subscriptionTitle ?? "Standard", tokenExpiresAt: expiry)
  }
  private nonisolated static func percent(_ used: Double, _ limit: Double) -> Double {
    limit > 0 ? min(100, max(0, (limit - used) / limit * 100)) : 0
  }
}

private struct KiroTokenResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let refreshToken: String?
}
private struct KiroUsageResponse: Decodable {
  struct Breakdown: Decodable {
    let displayName: String?
    let resourceType: String?
    let currentUsage: Double?
    let currentUsageWithPrecision: Double?
    let usageLimit: Double?
    let usageLimitWithPrecision: Double?
    let nextDateReset: Double?
    let freeTrialInfo: Trial?
  }
  struct Trial: Decodable {
    let currentUsage: Double?
    let currentUsageWithPrecision: Double?
    let usageLimit: Double?
    let usageLimitWithPrecision: Double?
    let freeTrialStatus: String?
    let freeTrialExpiry: Double?
  }
  struct Subscription: Decodable { let subscriptionTitle: String? }
  struct UserInfo: Decodable {
    let email: String?
    let userId: String?
  }
  let usageBreakdownList: [Breakdown]?
  let subscriptionInfo: Subscription?
  let userInfo: UserInfo?
  let nextDateReset: Double?
}
