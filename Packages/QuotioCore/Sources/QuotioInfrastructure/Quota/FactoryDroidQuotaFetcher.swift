import CryptoKit
import Darwin
import Foundation
import QuotioApplication
import QuotioDomain

public struct FactoryDroidCredential: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let activeOrganizationID: String?
  public let sourcePath: String

  public var accountKey: String { activeOrganizationID ?? "Factory Droid" }
}

public protocol FactoryDroidCredentialLoading: Sendable {
  func load() async -> FactoryDroidCredential?
}

public protocol FactoryDroidCredentialPersisting: Sendable {
  func canPersist(_ credential: FactoryDroidCredential) async -> Bool
  func persist(
    _ credential: FactoryDroidCredential,
    replacingRefreshToken: String
  ) async throws -> Bool
}

public struct LocalFactoryDroidCredentialStore: FactoryDroidCredentialLoading,
  FactoryDroidCredentialPersisting
{
  public static let credentialsPath = "~/.factory"

  private let directory: URL
  private let externalCredentials: any ExternalCredentialReading

  public init(
    directory: URL = URL(
      fileURLWithPath: NSString(string: credentialsPath).expandingTildeInPath, isDirectory: true),
    externalCredentials: any ExternalCredentialReading = ExternalKeychainCredentialReader()
  ) {
    self.directory = directory
    self.externalCredentials = externalCredentials
  }

  public func load() async -> FactoryDroidCredential? {
    let keychainKey = await Self.factoryCLIEncryptionKey(using: externalCredentials)
    let candidates: [(URL, Data?)] = [
      (directory.appendingPathComponent("auth.v2.loginkeychain"), keychainKey),
      (
        directory.appendingPathComponent("auth.v2.file"),
        try? Data(contentsOf: directory.appendingPathComponent("auth.v2.key"))
      ),
      (directory.appendingPathComponent("auth.v2.keyring"), keychainKey),
    ]
    var newest: (Date, FactoryDroidCredential)?
    for (url, key) in candidates {
      guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
        let date = values.contentModificationDate,
        let encrypted = try? String(contentsOf: url, encoding: .utf8),
        let credential = Self.decryptCredential(
          encrypted: encrypted, keyData: key, sourcePath: url.path)
      else { continue }
      if newest == nil || date > newest!.0 { newest = (date, credential) }
    }
    if let newest { return newest.1 }

    let legacyURL = directory.appendingPathComponent("auth.encrypted")
    guard let data = try? Data(contentsOf: legacyURL) else { return nil }
    if let credential = Self.parseCredential(data, sourcePath: legacyURL.path) { return credential }
    guard let encrypted = String(data: data, encoding: .utf8) else { return nil }
    return Self.decryptCredential(
      encrypted: encrypted, keyData: keychainKey, sourcePath: legacyURL.path)
  }

  public func canPersist(_ credential: FactoryDroidCredential) async -> Bool {
    guard let expected = credential.refreshToken else { return false }
    let url = URL(fileURLWithPath: credential.sourcePath)
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
      FileManager.default.isWritableFile(atPath: url.path),
      FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    else { return false }
    guard
      let document = Self.readDocument(
        at: url,
        keychainKey: await Self.factoryCLIEncryptionKey(using: externalCredentials)
      )
    else { return false }
    return Self.trimmed(document.json["refresh_token"] as? String) == expected
  }

  public func persist(_ credential: FactoryDroidCredential, replacingRefreshToken expected: String)
    async throws -> Bool
  {
    let url = URL(fileURLWithPath: credential.sourcePath)
    guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
      values.isSymbolicLink != true
    else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    let keychainKey = await Self.factoryCLIEncryptionKey(using: externalCredentials)
    return try Self.withCredentialWriteLock(directory: url.deletingLastPathComponent()) {
      guard
        var document = Self.readDocument(at: url, keychainKey: keychainKey),
        Self.trimmed(document.json["refresh_token"] as? String) == expected
      else { return false }
      document.json["access_token"] = credential.accessToken
      document.json["refresh_token"] = credential.refreshToken ?? expected
      let cleartext = try JSONSerialization.data(
        withJSONObject: document.json, options: [.sortedKeys])
      let output =
        if let key = document.key { try Self.encrypt(cleartext, key: key) } else { cleartext }
      try SecureAtomicFileWriter.write(output, to: url)
      return true
    }
  }

  public static func decryptCredential(encrypted: String, keyData: Data?, sourcePath: String)
    -> FactoryDroidCredential?
  {
    guard let key = normalizedKey(keyData),
      let cleartext = decrypt(encrypted.trimmingCharacters(in: .whitespacesAndNewlines), key: key)
    else { return nil }
    return parseCredential(cleartext, sourcePath: sourcePath)
  }

  private struct Document {
    var json: [String: Any]
    let key: Data?
  }

  private static func readDocument(at url: URL, keychainKey: Data?) -> Document? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["access_token"] != nil
    {
      return Document(json: json, key: nil)
    }
    let rawKey =
      url.lastPathComponent == "auth.v2.file"
      ? try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("auth.v2.key"))
      : keychainKey
    guard let encrypted = String(data: data, encoding: .utf8), let key = normalizedKey(rawKey),
      let cleartext = decrypt(encrypted.trimmingCharacters(in: .whitespacesAndNewlines), key: key),
      let json = try? JSONSerialization.jsonObject(with: cleartext) as? [String: Any]
    else { return nil }
    return Document(json: json, key: key)
  }

  private static func factoryCLIEncryptionKey(using reader: any ExternalCredentialReading) async
    -> Data?
  {
    for account in ["auth-encryption-key-security-cli", nil, "auth-encryption-key"] as [String?] {
      if let data = await reader.read(service: "Factory CLI", account: account)?.data {
        return data
      }
    }
    return nil
  }

  private static func parseCredential(_ data: Data, sourcePath: String) -> FactoryDroidCredential? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = trimmed(json["access_token"] as? String)
    else { return nil }
    return FactoryDroidCredential(
      accessToken: accessToken,
      refreshToken: trimmed(json["refresh_token"] as? String),
      activeOrganizationID: trimmed(json["active_organization_id"] as? String),
      sourcePath: sourcePath
    )
  }

  private static func normalizedKey(_ data: Data?) -> Data? {
    guard let data else { return nil }
    if data.count == 32 { return data }
    guard let text = String(data: data, encoding: .utf8),
      let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      decoded.count == 32
    else { return nil }
    return decoded
  }

  private static func decrypt(_ encrypted: String, key: Data) -> Data? {
    let parts = encrypted.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let nonceData = Data(base64Encoded: String(parts[0])),
      let tag = Data(base64Encoded: String(parts[1])),
      let ciphertext = Data(base64Encoded: String(parts[2])), tag.count == 16,
      let nonce = try? AES.GCM.Nonce(data: nonceData),
      let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    else { return nil }
    return try? AES.GCM.open(box, using: SymmetricKey(data: key))
  }

  private static func encrypt(_ data: Data, key: Data) throws -> Data {
    let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key))
    return Data(
      [
        Data(sealed.nonce).base64EncodedString(), sealed.tag.base64EncodedString(),
        sealed.ciphertext.base64EncodedString(),
      ].joined(separator: ":").utf8)
  }

  private static func withCredentialWriteLock<T>(
    directory: URL,
    operation: () throws -> T
  ) throws -> T {
    let manager = FileManager.default
    let lockURL = directory.appendingPathComponent("auth.v2.write.lock", isDirectory: true)
    let token = UUID().uuidString
    let pendingURL = directory.appendingPathComponent(
      "auth.v2.write.lock.\(token).pending", isDirectory: true)
    try manager.createDirectory(
      at: pendingURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? manager.removeItem(at: pendingURL) }
    let ownerData = try JSONSerialization.data(withJSONObject: [
      "token": token,
      "pid": ProcessInfo.processInfo.processIdentifier,
    ])
    let ownerURL = pendingURL.appendingPathComponent("owner.json")
    try ownerData.write(to: ownerURL, options: .withoutOverwriting)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)

    let deadline = Date().addingTimeInterval(2)
    while rename(pendingURL.path, lockURL.path) != 0 {
      guard [EEXIST, ENOTEMPTY, ENOTDIR, EISDIR].contains(errno), Date() < deadline else {
        throw InfrastructureQuotaFetchError.invalidResponse
      }
      if try reclaimAbandonedCredentialWriteLock(at: lockURL, manager: manager) {
        continue
      }
      Thread.sleep(forTimeInterval: 0.015)
    }

    defer {
      if credentialWriteLockSnapshot(at: lockURL, manager: manager)?.token == token {
        try? manager.removeItem(at: lockURL)
      }
    }
    return try operation()
  }

  private static func reclaimAbandonedCredentialWriteLock(
    at lockURL: URL,
    manager: FileManager
  ) throws -> Bool {
    guard let initial = credentialWriteLockSnapshot(at: lockURL, manager: manager),
      initial.isAbandoned
    else { return false }

    let reclaimURL = URL(fileURLWithPath: lockURL.path + ".reclaim", isDirectory: true)
    let token = UUID().uuidString
    let pendingURL = URL(
      fileURLWithPath: reclaimURL.path + ".\(token).pending", isDirectory: true)
    try manager.createDirectory(
      at: pendingURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? manager.removeItem(at: pendingURL) }
    let ownerData = try JSONSerialization.data(withJSONObject: [
      "token": token,
      "pid": ProcessInfo.processInfo.processIdentifier,
    ])
    let ownerURL = pendingURL.appendingPathComponent("owner.json")
    try ownerData.write(to: ownerURL, options: .withoutOverwriting)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)

    guard rename(pendingURL.path, reclaimURL.path) == 0 else {
      if let abandonedReclaim = credentialWriteLockSnapshot(at: reclaimURL, manager: manager),
        abandonedReclaim.isAbandoned,
        credentialWriteLockSnapshot(at: reclaimURL, manager: manager) == abandonedReclaim
      {
        try? manager.removeItem(at: reclaimURL)
      }
      return false
    }
    defer {
      if credentialWriteLockSnapshot(at: reclaimURL, manager: manager)?.token == token {
        try? manager.removeItem(at: reclaimURL)
      }
    }
    guard credentialWriteLockSnapshot(at: lockURL, manager: manager) == initial else {
      return false
    }
    try manager.removeItem(at: lockURL)
    return true
  }

  private static func credentialWriteLockSnapshot(
    at lockURL: URL,
    manager: FileManager
  ) -> CredentialWriteLockSnapshot? {
    guard let attributes = try? manager.attributesOfItem(atPath: lockURL.path),
      let modificationDate = attributes[.modificationDate] as? Date
    else { return nil }
    let ownerData = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json"))
    let owner = ownerData.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    return CredentialWriteLockSnapshot(
      token: owner?["token"] as? String,
      pid: (owner?["pid"] as? NSNumber)?.int32Value,
      modificationDate: modificationDate
    )
  }

  private struct CredentialWriteLockSnapshot: Equatable {
    let token: String?
    let pid: Int32?
    let modificationDate: Date

    var isAbandoned: Bool {
      if let pid {
        return kill(pid, 0) != 0 && errno == ESRCH
      }
      return Date().timeIntervalSince(modificationDate) >= 10
    }
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

public actor FactoryDroidQuotaFetcher: QuotaFetching {
  private static let clientID = "client_01HNM792M5G5G1A2THWPXKFMXB"

  public nonisolated let provider = QuotaProvider.factoryDroid
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let localCredentials: any FactoryDroidCredentialLoading
  private let credentialWriter: any FactoryDroidCredentialPersisting
  private let session: any QuotaHTTPSession
  private let limitsURL: URL
  private let profileURL: URL
  private let refreshURL: URL
  private let now: @Sendable () -> Date

  public init(
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    localCredentials: any FactoryDroidCredentialLoading,
    credentialWriter: any FactoryDroidCredentialPersisting,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    limitsURL: URL = URL(string: "https://api.factory.ai/api/billing/limits")!,
    profileURL: URL = URL(string: "https://api.factory.ai/api/app/auth/me")!,
    refreshURL: URL = URL(string: "https://api.workos.com/user_management/authenticate")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.vault = vault
    self.metadata = metadata
    self.localCredentials = localCredentials
    self.credentialWriter = credentialWriter
    self.session = session
    self.limitsURL = limitsURL
    self.profileURL = profileURL
    self.refreshURL = refreshURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let disabled = await metadata.disabledAccountIDs()
    var quotas: [String: ProviderQuota] = [:]
    var credentialAccountKeys = Set<String>()

    if let local = await localCredentials.load(), Self.includes(local.accountKey, in: request.scope)
    {
      let id = AccountIdentity.make(
        providerID: .init(rawValue: provider.rawValue), accountKey: local.accountKey
      ).id
      if !disabled.contains(id) {
        credentialAccountKeys.insert(local.accountKey)
        if let quota = try? await fetchLocal(local) { quotas[local.accountKey] = quota }
      }
    }

    if request.mode == .monitor {
      for account in await vault.accounts()
      where account.providerID.rawValue == provider.rawValue && !disabled.contains(account.id)
        && Self.includes(account.accountKey, in: request.scope)
      {
        guard let credential = await vault.credential(for: account.id),
          !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { continue }
        credentialAccountKeys.insert(account.accountKey)
        if let quota = await fetchQuota(token: credential.accessToken).quota {
          quotas[account.accountKey] = quota
        }
      }
    }
    return .init(
      quotas: quotas,
      credentialAvailability: credentialAccountKeys.isEmpty ? .missing : .present,
      credentialAccountKeys: credentialAccountKeys
    )
  }

  public nonisolated static func makeRefreshRequest(
    refreshToken: String, organizationID: String?,
    url: URL = URL(string: "https://api.workos.com/user_management/authenticate")!
  ) -> URLRequest {
    var values = [
      ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID),
    ]
    if let organizationID { values.append(("organization_id", organizationID)) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(
      values.map { form($0.0) + "=" + form($0.1) }.joined(separator: "&").utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  public nonisolated static func shouldRefresh(statusCode: Int?, didRefresh: Bool) -> Bool {
    statusCode == 401 && !didRefresh
  }

  public nonisolated static func map(_ data: Data, now: Date) -> ProviderQuota? {
    guard let response = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
      return nil
    }
    if response.usesTokenRateLimitsBilling == false {
      return ProviderQuota(
        models: [
          .init(
            name: "factory-billing-mode", percentage: -1, resetTime: "",
            presentation: .status(text: "legacy-billing"))
        ], lastUpdated: now)
    }
    var metrics: [QuotaMetric] = []
    append(response.limits?.standard, prefix: "factory-standard", now: now, to: &metrics)
    append(response.limits?.core, prefix: "factory-core", now: now, to: &metrics)
    if let cents = response.extraUsageBalanceCents {
      metrics.append(
        .init(
          name: "factory-extra-balance", percentage: -1, resetTime: "",
          presentation: .amount(value: max(0, cents) / 100, unit: .usd, semantics: .balance)))
    }
    return ProviderQuota(models: metrics, lastUpdated: now)
  }

  private func fetchLocal(_ original: FactoryDroidCredential) async throws -> ProviderQuota {
    var credential = original
    var didRefresh = false
    if Self.isExpiring(credential.accessToken, now: now()),
      let refreshed = try? await refresh(credential)
    {
      credential = refreshed
      didRefresh = true
    }
    var result = await fetchQuota(token: credential.accessToken)
    if Self.shouldRefresh(statusCode: result.statusCode, didRefresh: didRefresh),
      let refreshed = try? await refresh(credential)
    {
      result = await fetchQuota(token: refreshed.accessToken)
    }
    guard let quota = result.quota else { throw InfrastructureQuotaFetchError.invalidResponse }
    return quota
  }

  private func refresh(_ credential: FactoryDroidCredential) async throws -> FactoryDroidCredential
  {
    guard let token = credential.refreshToken, await credentialWriter.canPersist(credential) else {
      throw InfrastructureQuotaFetchError.forbidden
    }
    let (data, response) = try await session.data(
      for: Self.makeRefreshRequest(
        refreshToken: token, organizationID: credential.activeOrganizationID, url: refreshURL))
    guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let refreshed = try? JSONDecoder().decode(RefreshResponse.self, from: data)
    else { throw InfrastructureQuotaFetchError.invalidResponse }
    let updated = FactoryDroidCredential(
      accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? token,
      activeOrganizationID: credential.activeOrganizationID, sourcePath: credential.sourcePath)
    _ = try await credentialWriter.persist(updated, replacingRefreshToken: token)
    return updated
  }

  private func fetchQuota(token: String) async -> (quota: ProviderQuota?, statusCode: Int?) {
    async let displayName = profile(token: token)
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(
        for: Self.authorizedRequest(url: limitsURL, token: token))
    } catch { return (nil, nil) }
    guard let http = response as? HTTPURLResponse else { return (nil, nil) }
    if http.statusCode == 401 || http.statusCode == 403 {
      return (ProviderQuota(lastUpdated: now(), isForbidden: true), http.statusCode)
    }
    guard 200...299 ~= http.statusCode, var quota = Self.map(data, now: now()) else {
      return (nil, http.statusCode)
    }
    quota.accountDisplayName = await displayName
    return (quota, http.statusCode)
  }

  private func profile(token: String) async -> String? {
    guard
      let (data, response) = try? await session.data(
        for: Self.authorizedRequest(url: profileURL, token: token)),
      let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
      let profile = try? JSONDecoder().decode(ProfileResponse.self, from: data)
    else { return nil }
    return Self.trimmed(profile.userProfile?.email)
  }

  private nonisolated static func authorizedRequest(url: URL, token: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private nonisolated static func append(
    _ pool: LimitPool?, prefix: String, now: Date, to metrics: inout [QuotaMetric]
  ) {
    guard let pool else { return }
    for (suffix, window) in [
      ("five-hour", pool.fiveHour), ("weekly", pool.weekly), ("monthly", pool.monthly),
    ] {
      guard let window else { continue }
      let used = isExpired(window.windowEnd, now: now) ? 0 : window.usedPercent
      metrics.append(
        .init(
          name: prefix + "-" + suffix, percentage: max(0, min(100, 100 - used)),
          resetTime: window.windowEnd ?? ""))
    }
  }

  private nonisolated static func isExpired(_ value: String?, now: Date) -> Bool {
    guard let value else { return false }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)).map {
      $0 < now
    } ?? false
  }

  private nonisolated static func isExpiring(_ token: String, now: Date, leeway: TimeInterval = 60)
    -> Bool
  {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return true }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let expiry = json["exp"] as? NSNumber
    else { return true }
    return now.addingTimeInterval(leeway).timeIntervalSince1970 >= expiry.doubleValue
  }

  private nonisolated static func form(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
  }
  private nonisolated static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value
    case .importedAccounts(let values): values.contains(key)
    }
  }
}

private struct QuotaResponse: Decodable {
  let usesTokenRateLimitsBilling: Bool?
  let limits: LimitPools?
  let extraUsageBalanceCents: Double?
}
private struct LimitPools: Decodable {
  let standard: LimitPool?
  let core: LimitPool?
}
private struct LimitPool: Decodable {
  let fiveHour: LimitWindow?
  let weekly: LimitWindow?
  let monthly: LimitWindow?
}
private struct LimitWindow: Decodable {
  let usedPercent: Double
  let windowEnd: String?
  let secondsRemaining: Double?
}
private struct ProfileResponse: Decodable {
  struct UserProfile: Decodable { let email: String? }
  let userProfile: UserProfile?
}
private struct RefreshResponse: Decodable {
  let accessToken: String
  let refreshToken: String?
  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
  }
}
