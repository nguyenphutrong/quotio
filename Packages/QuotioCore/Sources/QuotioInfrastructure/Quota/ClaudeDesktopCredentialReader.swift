import CommonCrypto
import CryptoKit
import Foundation
import QuotioApplication
import SQLite3

public struct ClaudeDesktopCredentialReader: ClaudeDesktopCredentialLoading {
  private enum Error: Swift.Error {
    case invalidData
  }

  private let configPath: String
  private let cookiePaths: [String]
  private let externalCredentials: any ExternalCredentialReading
  private let now: @Sendable () -> Date

  public init(
    appSupportPath: String = "~/Library/Application Support/Claude",
    externalCredentials: any ExternalCredentialReading = ExternalKeychainCredentialReader(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let expanded = NSString(string: appSupportPath).expandingTildeInPath
    configPath = (expanded as NSString).appendingPathComponent("config.json")
    cookiePaths = [
      (expanded as NSString).appendingPathComponent("Cookies"),
      (expanded as NSString).appendingPathComponent("Network/Cookies"),
    ]
    self.externalCredentials = externalCredentials
    self.now = now
  }

  public func hasCredentialMaterial() -> Bool {
    guard let data = FileManager.default.contents(atPath: configPath),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["oauth:tokenCache"] is String || json["oauth:tokenCacheV2"] is String
    else { return false }
    return cookiePaths.contains { FileManager.default.fileExists(atPath: $0) }
  }

  public func credential() async -> ClaudeQuotaCredential? {
    guard hasCredentialMaterial(),
      let passwordData = await externalCredentials.read(
        service: "Claude Safe Storage", account: "Claude Key")?.data,
      let password = String(data: passwordData, encoding: .utf8),
      let key = try? Self.deriveKey(password),
      let organization = activeOrganization(key: key),
      let data = FileManager.default.contents(atPath: configPath),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let cached =
      Self.bestCredential(
        in: Self.decodeCache(root["oauth:tokenCacheV2"], key: key),
        organization: organization,
        now: now()
      )
      ?? Self.bestCredential(
        in: Self.decodeCache(root["oauth:tokenCache"], key: key),
        organization: organization,
        now: now()
      )
    return cached.map {
      ClaudeQuotaCredential(
        accountKey: "Claude Desktop", accessToken: $0.accessToken, expiresAt: $0.expiresAt)
    }
  }

  private func activeOrganization(key: Data) -> String? {
    for path in cookiePaths where FileManager.default.fileExists(atPath: path) {
      var database: OpaquePointer?
      guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let database { sqlite3_close(database) }
        continue
      }
      defer { sqlite3_close(database) }
      let sql =
        "SELECT host_key, value, encrypted_value FROM cookies WHERE name='lastActiveOrg' AND host_key IN ('.claude.ai','claude.ai') ORDER BY last_update_utc DESC LIMIT 1"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { continue }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { continue }
      let host = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "claude.ai"
      let plain = sqlite3_column_text(statement, 1).map { String(cString: $0) }
      if let plain, UUID(uuidString: plain) != nil { return plain.lowercased() }
      guard let blob = sqlite3_column_blob(statement, 2) else { continue }
      let encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
      guard let decrypted = try? Self.decrypt(encrypted, key: key) else { continue }
      let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
      guard decrypted.starts(with: hostHash),
        let value = String(data: decrypted.dropFirst(hostHash.count), encoding: .utf8),
        UUID(uuidString: value) != nil
      else { continue }
      return value.lowercased()
    }
    return nil
  }

  private static func decodeCache(_ value: Any?, key: Data) -> [String: Any]? {
    guard let encoded = value as? String,
      let encrypted = Data(base64Encoded: encoded),
      let decrypted = try? decrypt(encrypted, key: key)
    else { return nil }
    return try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any]
  }

  private static func bestCredential(
    in cache: [String: Any]?, organization: String, now: Date
  ) -> (accessToken: String, expiresAt: Date)? {
    guard let cache else { return nil }
    let marker = ":https://api.anthropic.com:"
    let minimumExpiry = now.addingTimeInterval(120).timeIntervalSince1970 * 1_000
    var candidates: [(rank: Int, accessToken: String, expiresAt: Date)] = []
    for (key, raw) in cache {
      guard key.lowercased().contains(organization),
        let markerRange = key.range(of: marker),
        let entry = raw as? [String: Any],
        let token = entry["token"] as? String, !token.isEmpty,
        let expiry = (entry["expiresAt"] as? NSNumber)?.doubleValue,
        expiry > minimumExpiry
      else { continue }
      let scopes = key[markerRange.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
      guard scopes.contains("user:profile") else { continue }
      let clientID = String(key[..<markerRange.lowerBound].split(separator: ":").first ?? "")
      let fullScope = scopes.contains("user:inference")
      let production = clientID == ClaudeQuotaFetcher.clientID
      let rank = (production && fullScope ? 100 : 0) + (fullScope ? 10 : 0) + scopes.count
      candidates.append(
        (rank, token, Date(timeIntervalSince1970: expiry / 1_000)))
    }
    return candidates.max { $0.rank < $1.rank }.map { ($0.accessToken, $0.expiresAt) }
  }

  private static func deriveKey(_ password: String) throws -> Data {
    let passwordData = Data(password.utf8)
    let salt = Data("saltysalt".utf8)
    var key = Data(count: kCCKeySizeAES128)
    let keyCount = key.count
    let status = key.withUnsafeMutableBytes { keyBytes in
      passwordData.withUnsafeBytes { passwordBytes in
        salt.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.bindMemory(to: Int8.self).baseAddress,
            passwordData.count,
            saltBytes.bindMemory(to: UInt8.self).baseAddress,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1_003,
            keyBytes.bindMemory(to: UInt8.self).baseAddress,
            keyCount
          )
        }
      }
    }
    guard status == kCCSuccess else { throw Error.invalidData }
    return key
  }

  private static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
    guard encrypted.starts(with: Data("v10".utf8)) else { throw Error.invalidData }
    let payload = encrypted.dropFirst(3)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: payload.count + kCCBlockSizeAES128)
    var outputLength = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { outputBytes in
      payload.withUnsafeBytes { payloadBytes in
        key.withUnsafeBytes { keyBytes in
          iv.withUnsafeBytes { ivBytes in
            CCCrypt(
              CCOperation(kCCDecrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              keyBytes.baseAddress,
              key.count,
              ivBytes.baseAddress,
              payloadBytes.baseAddress,
              payload.count,
              outputBytes.baseAddress,
              capacity,
              &outputLength
            )
          }
        }
      }
    }
    guard status == kCCSuccess else { throw Error.invalidData }
    output.count = outputLength
    return output
  }
}
