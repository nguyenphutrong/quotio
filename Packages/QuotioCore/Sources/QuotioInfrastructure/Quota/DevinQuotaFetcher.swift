import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3

public struct DevinCredential: Sendable, Equatable {
  public let apiKey: String
  public let apiServerURL: String?

  public init(apiKey: String, apiServerURL: String?) {
    self.apiKey = apiKey
    self.apiServerURL = apiServerURL
  }
}

public protocol DevinCredentialDatabaseReading: Sendable {
  func credential(path: String) -> DevinCredential?
}

public struct LocalDevinCredentialDatabaseReader: DevinCredentialDatabaseReading {
  public init() {}

  public func credential(path: String) -> DevinCredential? {
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
        database, "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1", -1,
        &statement, nil) == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let bytes = sqlite3_column_text(statement, 0)
    else { return nil }
    let value = String(cString: bytes)
    guard let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let apiKey = DevinQuotaFetcher.trimmed(object["apiKey"] as? String)
    else { return nil }
    return DevinCredential(apiKey: apiKey, apiServerURL: nil)
  }
}

public actor DevinQuotaFetcher: QuotaFetching {
  public static let accountKey = "Devin"
  public static let credentialsPath = "~/.local/share/devin/credentials.toml"
  public static let stateDBPath =
    "~/Library/Application Support/Devin/User/globalStorage/state.vscdb"
  public static let defaultAPIServerURL = "https://server.codeium.com"

  public nonisolated let provider = QuotaProvider.devin
  private let files: any QuotaCredentialFileReading
  private let database: any DevinCredentialDatabaseReading
  private let session: any QuotaHTTPSession
  private let credentialsPath: String
  private let stateDBPath: String
  private let now: @Sendable () -> Date

  public init(
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    database: any DevinCredentialDatabaseReading = LocalDevinCredentialDatabaseReader(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    credentialsPath: String = DevinQuotaFetcher.credentialsPath,
    stateDBPath: String = DevinQuotaFetcher.stateDBPath,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.files = files
    self.database = database
    self.session = session
    self.credentialsPath = credentialsPath
    self.stateDBPath = stateDBPath
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard Self.includes(Self.accountKey, in: request.scope) else {
      return QuotaProviderOutput(quotas: [:], credentialAvailability: .missing)
    }
    var candidates: [DevinCredential] = []
    if let data = await files.read(path: credentialsPath),
      let text = String(data: data, encoding: .utf8),
      let credential = Self.parseCredentialsTOML(text)
    {
      candidates.append(credential)
    }
    if let credential = database.credential(path: stateDBPath) { candidates.append(credential) }

    var forbidden: ProviderQuota?
    for credential in candidates {
      guard let quota = try? await fetchQuota(credential) else { continue }
      if quota.isForbidden {
        forbidden = quota
      } else {
        return QuotaProviderOutput(
          quotas: [Self.accountKey: quota], credentialAvailability: .present)
      }
    }
    return QuotaProviderOutput(
      quotas: forbidden.map { [Self.accountKey: $0] } ?? [:],
      credentialAvailability: candidates.isEmpty ? .missing : .present
    )
  }

  public nonisolated static func parseCredentialsTOML(_ text: String) -> DevinCredential? {
    guard let apiKey = tomlString(text, key: "windsurf_api_key") else { return nil }
    return DevinCredential(
      apiKey: apiKey, apiServerURL: tomlString(text, key: "api_server_url").flatMap(cleanServerURL))
  }

  public nonisolated static func map(_ data: Data, now: Date = Date()) -> ProviderQuota? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let status = root["userStatus"] as? [String: Any]
    else { return nil }
    let planStatus = status["planStatus"] as? [String: Any] ?? [:]
    let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
    let hideDaily = bool(planInfo["hideDailyQuota"]) == true
    let daily = number(planStatus["dailyQuotaRemainingPercent"])
    let weekly = number(planStatus["weeklyQuotaRemainingPercent"])
    var metrics: [QuotaMetric] = []
    if !hideDaily, let daily {
      metrics.append(
        .init(
          name: "devin-daily", percentage: clamp(daily),
          resetTime: reset(planStatus["dailyQuotaResetAtUnix"])))
    }
    if let weekly {
      metrics.append(
        .init(
          name: "devin-weekly", percentage: clamp(weekly),
          resetTime: reset(planStatus["weeklyQuotaResetAtUnix"])))
    } else if hideDaily, let daily {
      metrics.append(
        .init(
          name: "devin-weekly", percentage: clamp(daily),
          resetTime: reset(planStatus["weeklyQuotaResetAtUnix"])))
    }
    if let micros = number(planStatus["overageBalanceMicros"]) {
      metrics.append(
        .init(
          name: "devin-extra-balance", percentage: -1, resetTime: "",
          presentation: .amount(value: max(0, micros) / 1_000_000, unit: .usd, semantics: .balance))
      )
    }
    guard !metrics.isEmpty else { return nil }
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: trimmed(planInfo["planName"] as? String))
  }

  private func fetchQuota(_ credential: DevinCredential) async throws -> ProviderQuota {
    let server = credential.apiServerURL ?? Self.defaultAPIServerURL
    guard
      let url = URL(string: server + "/exa.seat_management_pb.SeatManagementService/GetUserStatus")
    else { throw InfrastructureQuotaFetchError.invalidURL }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "metadata": [
        "apiKey": credential.apiKey, "ideName": "devin", "ideVersion": "1.108.2",
        "extensionName": "devin", "extensionVersion": "1.108.2", "locale": "en",
      ]
    ])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      return ProviderQuota(lastUpdated: now(), isForbidden: true)
    }
    guard 200...299 ~= http.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(http.statusCode)
    }
    guard let quota = Self.map(data, now: now()) else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return quota
  }

  fileprivate nonisolated static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
  private nonisolated static func number(_ value: Any?) -> Double? {
    value is NSNumber ? (value as? NSNumber)?.doubleValue : (value as? String).flatMap(Double.init)
  }
  private nonisolated static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return (value as? String).flatMap(Bool.init)
  }
  private nonisolated static func clamp(_ value: Double) -> Double { max(0, min(100, value)) }
  private nonisolated static func reset(_ value: Any?) -> String {
    number(value).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? ""
  }
  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
  private nonisolated static func tomlString(_ text: String, key: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
      let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
      else { continue }
      var value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      var quote: Character?
      var escaped = false
      for index in value.indices {
        let character = value[index]
        if escaped {
          escaped = false
        } else if quote == "\"" && character == "\\" {
          escaped = true
        } else if let active = quote {
          if character == active { quote = nil }
        } else if character == "\"" || character == "'" {
          quote = character
        } else if character == "#" {
          value = String(value[..<index])
          break
        }
      }
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.count >= 2,
        (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'")
      {
        value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }
  private nonisolated static func cleanServerURL(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("https://") else { return nil }
    return value.hasSuffix("/") ? String(value.dropLast()) : value
  }
}
