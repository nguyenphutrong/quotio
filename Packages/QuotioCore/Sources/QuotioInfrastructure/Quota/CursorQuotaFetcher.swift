import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3

public struct CursorCredential: Equatable, Sendable {
  public let accessToken: String?
  public let email: String?
  public let membershipType: String?
  public let subscriptionStatus: String?

  public init(
    accessToken: String?, email: String?, membershipType: String?, subscriptionStatus: String?
  ) {
    self.accessToken = accessToken
    self.email = email
    self.membershipType = membershipType
    self.subscriptionStatus = subscriptionStatus
  }
}

public protocol CursorCredentialDatabaseReading: Sendable {
  func credential(path: String) -> CursorCredential?
}

public protocol IDEApplicationChecking: Sendable {
  func isInstalled(paths: [String]) -> Bool
}

public struct LocalIDEApplicationChecker: IDEApplicationChecking {
  public init() {}

  public func isInstalled(paths: [String]) -> Bool {
    paths.contains {
      FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath)
    }
  }
}

public struct LocalCursorCredentialDatabaseReader: CursorCredentialDatabaseReading {
  public init() {}

  public func credential(path: String) -> CursorCredential? {
    let expanded = NSString(string: path).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else { return nil }
    let uri = URL(fileURLWithPath: expanded).absoluteString + "?mode=ro&immutable=1"
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
        database, "SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%'", -1, &statement,
        nil) == SQLITE_OK
    else {
      return nil
    }
    defer { sqlite3_finalize(statement) }

    var values: [String: String] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let key = sqlite3_column_text(statement, 0),
        let value = sqlite3_column_text(statement, 1)
      else { continue }
      values[String(cString: key)] = String(cString: value)
    }
    let credential = CursorCredential(
      accessToken: values["cursorAuth/accessToken"],
      email: values["cursorAuth/cachedEmail"],
      membershipType: values["cursorAuth/stripeMembershipType"],
      subscriptionStatus: values["cursorAuth/stripeSubscriptionStatus"]
    )
    return credential.accessToken != nil || credential.email != nil ? credential : nil
  }
}

public actor CursorQuotaFetcher: QuotaFetching {
  public static let stateDBPath =
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  public static let applicationPaths = ["/Applications/Cursor.app", "~/Applications/Cursor.app"]

  public nonisolated let provider = QuotaProvider.cursor
  private let database: any CursorCredentialDatabaseReading
  private let applications: any IDEApplicationChecking
  private let session: any QuotaHTTPSession
  private let stateDBPath: String
  private let now: @Sendable () -> Date
  private let usageURL: URL

  public init(
    database: any CursorCredentialDatabaseReading = LocalCursorCredentialDatabaseReader(),
    applications: any IDEApplicationChecking = LocalIDEApplicationChecker(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    stateDBPath: String = CursorQuotaFetcher.stateDBPath,
    usageURL: URL = URL(string: "https://api2.cursor.sh/auth/usage-summary")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.applications = applications
    self.session = session
    self.stateDBPath = stateDBPath
    self.usageURL = usageURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard Self.allows(request), applications.isInstalled(paths: Self.applicationPaths) else {
      return QuotaProviderOutput(quotas: [:], credentialAvailability: .missing)
    }
    guard let credential = database.credential(path: stateDBPath),
      let token = credential.accessToken
    else {
      return QuotaProviderOutput(quotas: [:], credentialAvailability: .missing)
    }
    let quota = await fetchQuota(token: token, credential: credential)
    let accountKey = credential.email ?? "Cursor User"
    guard Self.includes(accountKey, in: request.scope) else {
      return QuotaProviderOutput(quotas: [:], credentialAvailability: .present)
    }
    return QuotaProviderOutput(quotas: [accountKey: quota], credentialAvailability: .present)
  }

  private func fetchQuota(token: String, credential: CursorCredential) async -> ProviderQuota {
    var request = URLRequest(url: usageURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await session.data(for: request),
      let response = response as? HTTPURLResponse, response.statusCode == 200
    else {
      return Self.fallback(credential, now: now())
    }
    return Self.map(data, credential: credential, now: now())
  }

  public nonisolated static func map(_ data: Data, credential: CursorCredential, now: Date = Date())
    -> ProviderQuota
  {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return fallback(credential, now: now)
    }
    let membership = root["membershipType"] as? String ?? credential.membershipType
    let reset =
      (root["billingCycleEnd"] as? String).flatMap(fractionalDate).map {
        ISO8601DateFormatter().string(from: $0)
      } ?? ""
    var metrics: [QuotaMetric] = []
    if let usage = root["individualUsage"] as? [String: Any],
      let plan = usage["plan"] as? [String: Any], plan["enabled"] as? Bool == true
    {
      let used = plan["used"] as? Int ?? 0
      let limit = plan["limit"] as? Int ?? 0
      let remaining = plan["remaining"] as? Int ?? 0
      metrics.append(
        .init(
          name: "plan-usage",
          percentage: limit > 0 ? clamp(Double(remaining) / Double(limit) * 100) : 100,
          resetTime: reset, used: used, limit: limit, remaining: remaining))
    }
    if let usage = root["individualUsage"] as? [String: Any],
      let demand = usage["onDemand"] as? [String: Any], demand["enabled"] as? Bool == true
    {
      let used = demand["used"] as? Int ?? 0
      let limit = demand["limit"] as? Int
      let remaining = demand["remaining"] as? Int
      let percentage =
        limit.flatMap { $0 > 0 ? Double(remaining ?? 0) / Double($0) * 100 : nil }.map(clamp) ?? 100
      metrics.append(
        .init(
          name: "on-demand", percentage: percentage, resetTime: "", used: used, limit: limit,
          remaining: remaining))
    }
    if metrics.isEmpty {
      metrics = [
        .init(
          name: "cursor-usage", percentage: root["isUnlimited"] as? Bool == true ? 100 : -1,
          resetTime: "")
      ]
    }
    return ProviderQuota(models: metrics, lastUpdated: now, planType: displayPlan(membership))
  }

  private nonisolated static func fallback(_ credential: CursorCredential, now: Date)
    -> ProviderQuota
  {
    ProviderQuota(
      models: [.init(name: "cursor-usage", percentage: -1, resetTime: "")], lastUpdated: now,
      planType: displayPlan(credential.membershipType))
  }

  private nonisolated static func allows(_ request: QuotaFetchRequest) -> Bool {
    if case .provider = request.scope { return request.force }
    return true
  }
  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
  private nonisolated static func fractionalDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
  private nonisolated static func clamp(_ value: Double) -> Double { min(100, max(0, value)) }
  private nonisolated static func displayPlan(_ value: String?) -> String? {
    value?.replacingOccurrences(of: "_", with: " ").split(separator: " ").map {
      $0.prefix(1).uppercased() + $0.dropFirst().lowercased()
    }.joined(separator: " ")
  }
}
