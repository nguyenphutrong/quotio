import Foundation
import SQLite3

public struct NativeAntigravityCredentialReader: AntigravityCredentialReading {
  public static let databasePath =
    "~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb"

  private let path: String
  private let session: any QuotaHTTPSession
  private let userInfoURL: URL

  public init(
    path: String = NativeAntigravityCredentialReader.databasePath,
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    userInfoURL: URL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
  ) {
    self.path = path
    self.session = session
    self.userInfoURL = userInfoURL
  }

  public func credentials() async -> [AntigravityCredential] {
    guard let value = Self.readState(path: path),
      let token = Self.extractOAuthInfo(base64Data: value),
      let accessToken = token.accessToken
    else { return [] }
    let accountKey = await accountKey(accessToken: accessToken)
    let expiry = token.expiry.map { raw in
      let seconds = TimeInterval(raw)
      return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
    }
    return [
      AntigravityCredential(
        accountKey: accountKey,
        accessToken: accessToken,
        refreshToken: token.refreshToken,
        expiresAt: expiry,
        origin: .native
      )
    ]
  }

  static func readState(path: String) -> String? {
    let expanded = NSString(string: path).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else { return nil }
    let uri = URL(fileURLWithPath: expanded).absoluteString + "?mode=ro"
    var database: OpaquePointer?
    guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
    else {
      if let database { sqlite3_close(database) }
      return nil
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT value FROM ItemTable WHERE key = 'jetskiStateSync.agentManagerInitState' LIMIT 1",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let value = sqlite3_column_text(statement, 0)
    else { return nil }
    return String(cString: value)
  }

  static func extractOAuthInfo(base64Data: String) -> (
    accessToken: String?, refreshToken: String?, expiry: Int64?
  )? {
    guard let data = Data(base64Encoded: base64Data) else { return nil }
    var offset = 0
    while offset + 10 < data.count {
      if data[offset] == 0x32,
        let range = try? lengthDelimitedRange(data, offset: offset + 1),
        range.count > 100,
        range.count < 2_000
      {
        let candidate = Data(data[range])
        if let tokenData = try? findField(candidate, targetField: 1),
          let token = String(data: tokenData, encoding: .utf8),
          token.hasPrefix("ya29.")
        {
          return oauthInfo(candidate, accessToken: token)
        }
      }
      offset += 1
    }
    guard let oauthData = try? findField(data, targetField: 6) else {
      return nil
    }
    let access = (try? findField(oauthData, targetField: 1)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    return oauthInfo(oauthData, accessToken: access)
  }

  private func accountKey(accessToken: String) async -> String {
    var request = URLRequest(url: userInfoURL)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse,
      200...299 ~= http.statusCode,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let email = object["email"] as? String,
      !email.isEmpty
    else { return "Antigravity" }
    return email
  }

  private static func oauthInfo(_ data: Data, accessToken: String?) -> (
    accessToken: String?, refreshToken: String?, expiry: Int64?
  ) {
    let refresh = (try? findField(data, targetField: 3)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    var expiry: Int64?
    if let expiryData = try? findField(data, targetField: 4),
      expiryData.count > 1,
      expiryData[0] == 0x08,
      let (seconds, _) = try? readVarint(expiryData, offset: 1)
    {
      expiry = Int64(bitPattern: seconds)
    }
    return (accessToken, refresh, expiry)
  }

  private static func findField(_ data: Data, targetField: UInt32) throws -> Data? {
    var offset = 0
    while offset < data.count {
      let (tag, valueOffset) = try readVarint(data, offset: offset)
      let wireType = UInt8(tag & 7)
      if UInt32(tag >> 3) == targetField, wireType == 2 {
        return Data(data[try lengthDelimitedRange(data, offset: valueOffset)])
      }
      offset = try skipField(data, offset: valueOffset, wireType: wireType)
    }
    return nil
  }

  private static func skipField(_ data: Data, offset: Int, wireType: UInt8) throws -> Int {
    switch wireType {
    case 0: return try readVarint(data, offset: offset).1
    case 1:
      guard offset <= data.count - 8 else { throw CocoaError(.fileReadCorruptFile) }
      return offset + 8
    case 2: return try lengthDelimitedRange(data, offset: offset).upperBound
    case 5:
      guard offset <= data.count - 4 else { throw CocoaError(.fileReadCorruptFile) }
      return offset + 4
    default: throw CocoaError(.fileReadCorruptFile)
    }
  }

  private static func lengthDelimitedRange(_ data: Data, offset: Int) throws -> Range<Int> {
    let (length, start) = try readVarint(data, offset: offset)
    guard length <= UInt64(data.count - start) else { throw CocoaError(.fileReadCorruptFile) }
    return start..<(start + Int(length))
  }

  private static func readVarint(_ data: Data, offset: Int) throws -> (UInt64, Int) {
    var result: UInt64 = 0
    var position = offset
    for index in 0..<10 {
      guard position >= 0, position < data.count else { throw CocoaError(.fileReadCorruptFile) }
      let byte = data[position]
      let value = byte & 0x7f
      guard index < 9 || value <= 1 else { throw CocoaError(.fileReadCorruptFile) }
      result |= UInt64(value) << UInt64(index * 7)
      position += 1
      if byte & 0x80 == 0 { return (result, position) }
    }
    throw CocoaError(.fileReadCorruptFile)
  }
}
