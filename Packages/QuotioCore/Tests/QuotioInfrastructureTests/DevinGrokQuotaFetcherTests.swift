import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3
import XCTest

@testable import QuotioInfrastructure

final class DevinGrokQuotaFetcherTests: XCTestCase {
  func testDevinParsesQuotedCommentsAndRejectsInsecureServerURL() {
    let native = DevinQuotaFetcher.parseCredentialsTOML("""
      windsurf_api_key = "native-token"
      api_server_url = "https://server.codeium.test/"
      """)
    let insecure = DevinQuotaFetcher.parseCredentialsTOML("""
      windsurf_api_key = "native-token"
      api_server_url = "http://server.codeium.test"
      """)
    let quotedHash = DevinQuotaFetcher.parseCredentialsTOML("""
      windsurf_api_key = "native#token" # account credential
      api_server_url = "https://server.codeium.test/path#fragment" # API endpoint
      """)

    XCTAssertEqual(
      native,
      DevinCredential(apiKey: "native-token", apiServerURL: "https://server.codeium.test"))
    XCTAssertNil(insecure?.apiServerURL)
    XCTAssertEqual(
      quotedHash,
      DevinCredential(
        apiKey: "native#token", apiServerURL: "https://server.codeium.test/path#fragment"))
  }

  func testDevinPreservesNativeSourcesScopeMappingAndRequestInBothModes() async throws {
    let files = ProviderFileReader(
      data: Data(
        "windsurf_api_key = \"native#token\" # comment\napi_server_url = \"https://server.test/\""
          .utf8))
    let session = ProviderSession { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://server.test/exa.seat_management_pb.SeatManagementService/GetUserStatus")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
      let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      XCTAssertEqual((body["metadata"] as? [String: Any])?["apiKey"] as? String, "native#token")
      return (
        #"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max","hideDailyQuota":true},"dailyQuotaRemainingPercent":30,"overageBalanceMicros":"1250000"}}}"#,
        200
      )
    }
    let fetcher = DevinQuotaFetcher(
      files: files, database: ProviderDevinDatabase(nil), session: session)
    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .devin, scope: .account("Devin"), mode: mode))
      XCTAssertEqual(output.credentialAvailability, .present)
      XCTAssertEqual(output.quotas["Devin"]?.planType, "Max")
      XCTAssertEqual(
        output.quotas["Devin"]?.models.first { $0.name == "devin-weekly" }?.percentage, 30)
      XCTAssertEqual(
        output.quotas["Devin"]?.models.first { $0.name == "devin-extra-balance" }?.presentation,
        .amount(value: 1.25, unit: .usd, semantics: .balance))
    }
    let excluded = try await fetcher.fetch(
      .init(provider: .devin, scope: .account("Other"), mode: .monitor))
    XCTAssertEqual(excluded.credentialAvailability, .missing)
  }

  func testDevinFallsBackAfterForbiddenAndReadsSQLiteReadOnly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.vscdb").path
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        database,
        "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{\"apiKey\":\"db-token\"}')",
        nil, nil, nil), SQLITE_OK)
    sqlite3_close(database)
    XCTAssertEqual(
      LocalDevinCredentialDatabaseReader().credential(path: path),
      DevinCredential(apiKey: "db-token", apiServerURL: nil))

    let files = ProviderFileReader(data: Data("windsurf_api_key = \"bad\"".utf8))
    let session = ProviderSession { request in
      let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      let token = (body["metadata"] as! [String: Any])["apiKey"] as! String
      return token == "bad"
        ? ("", 403) : (#"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":72}}}"#, 200)
    }
    let output = try await DevinQuotaFetcher(
      files: files, database: LocalDevinCredentialDatabaseReader(), session: session,
      stateDBPath: path
    ).fetch(.init(provider: .devin, mode: .monitor))
    XCTAssertEqual(output.quotas["Devin"]?.isForbidden, false)
    XCTAssertEqual(output.quotas["Devin"]?.models.first?.percentage, 72)
  }

  func testDevinMapsRejectedCredentialsButIgnoresOtherHTTPFailures() async throws {
    for status in [401, 403] {
      let output = try await DevinQuotaFetcher(
        files: ProviderFileReader(data: Data("windsurf_api_key = \"token\"".utf8)),
        database: ProviderDevinDatabase(nil),
        session: ProviderSession { _ in ("", status) }
      ).fetch(.init(provider: .devin, mode: .monitor))
      XCTAssertEqual(output.quotas["Devin"]?.isForbidden, true)
      XCTAssertEqual(output.credentialAvailability, .present)
    }

    let failed = try await DevinQuotaFetcher(
      files: ProviderFileReader(data: Data("windsurf_api_key = \"token\"".utf8)),
      database: ProviderDevinDatabase(nil),
      session: ProviderSession { _ in ("", 500) }
    ).fetch(.init(provider: .devin, mode: .monitor))
    XCTAssertTrue(failed.quotas.isEmpty)
    XCTAssertEqual(failed.credentialAvailability, .present)
  }

  func testGrokParsesMultipleAccountsSkipsInvalidEntriesAndUsesDefaultClientID() {
    let data = Data(
      #"{"account-a::client-a":{"key":"token-a","refresh_token":"refresh-a"},"account-b::client-b":{"key":"token-b"},"account-without-client":{"key":"token","refresh_token":"refresh"},"invalid":{"refresh_token":"refresh-only"}}"#
        .utf8)

    let candidates = GrokQuotaFetcher.loadCandidates(data: data)

    XCTAssertEqual(
      candidates.map(\.entryKey),
      ["account-a::client-a", "account-b::client-b", "account-without-client"])
    XCTAssertEqual(
      candidates.map(\.clientID),
      ["client-a", "client-b", GrokQuotaFetcher.defaultClientID])
  }

  func testGrokMapsOnlyWeeklyPeriodAndPreservesDisplayName() throws {
    let weekly = Data(
      #"{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-08T00:00:00Z"},"onDemandCap":{"val":2500}}}"#
        .utf8)
    let monthly = Data(
      #"{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2030-02-01T00:00:00Z"}}}"#
        .utf8)

    let weeklyQuota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(
        weekly, plan: "SuperGrok", displayName: "person@example.com"))
    let monthlyQuota = try XCTUnwrap(
      GrokQuotaFetcher.mapBilling(monthly, plan: nil, displayName: "person@example.com"))

    XCTAssertEqual(weeklyQuota.models.first { $0.name == "grok-weekly" }?.percentage, 75)
    XCTAssertEqual(
      weeklyQuota.models.first { $0.name == "grok-extra-usage" }?.presentation,
      .status(text: "grok-cap:2500"))
    XCTAssertEqual(weeklyQuota.accountDisplayName, "person@example.com")
    XCTAssertNil(monthlyQuota.models.first { $0.name == "grok-weekly" })
  }

  func testGrokScopesAccountsRefreshesAndMapsHeadersPlanAndForbiddenInBothModes() async throws {
    let auth = Data(
      #"{"account-a::client+a":{"key":"expired","refresh_token":"refresh&value","expires_at":"2020-01-01T00:00:00Z"},"account-b":{"key":"denied"},"invalid":{"refresh_token":"only"}}"#
        .utf8)
    let files = ProviderFileReader(data: auth)
    let writer = ProviderGrokWriter()
    let session = ProviderSession { request in
      switch request.url!.path {
      case "/oauth2/token":
        XCTAssertEqual(
          String(data: request.httpBody!, encoding: .utf8),
          "grant_type=refresh_token&client_id=client%2Ba&refresh_token=refresh%26value")
        return (#"{"access_token":"rotated","refresh_token":"new-refresh","expires_in":3600}"#, 200)
      case "/v1/settings": return (#"{"subscription_tier_display":"SuperGrok"}"#, 200)
      default:
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-XAI-Token-Auth"), "xai-grok-cli")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Quotio")
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer denied" {
          return ("", 403)
        }
        return (
          #"{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-08T00:00:00Z"},"onDemandCap":{"val":2500}}}"#,
          200
        )
      }
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fetcher = GrokQuotaFetcher(files: files, writer: writer, session: session, now: { now })
    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .grok, scope: .account("account-a::client+a"), mode: mode))
      XCTAssertEqual(output.quotas.keys.sorted(), ["account-a::client+a"])
      XCTAssertEqual(output.credentialAccountKeys, ["account-a::client+a"])
      XCTAssertEqual(output.quotas["account-a::client+a"]?.planType, "SuperGrok")
      XCTAssertEqual(
        output.quotas["account-a::client+a"]?.models.first { $0.name == "grok-weekly" }?.percentage,
        75)
      XCTAssertEqual(
        output.quotas["account-a::client+a"]?.models.first { $0.name == "grok-extra-usage" }?.presentation,
        .status(text: "grok-cap:2500"))
    }
    let denied = try await fetcher.fetch(
      .init(provider: .grok, scope: .account("account-b"), mode: .monitor))
    XCTAssertEqual(denied.quotas["account-b"]?.isForbidden, true)
    XCTAssertEqual(denied.credentialAccountKeys, ["account-b"])
    XCTAssertEqual(denied.quotas["account-b"]?.accountDisplayName, "Grok account-")
    let persistedCount = await writer.persistedCount()
    XCTAssertEqual(persistedCount, 2)
  }

  func testGrokLocalWriterPreservesUnknownFieldsPermissionsAndRefusesSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("auth.json")
    try Data(#"{"target":{"key":"old","unknown":"keep"},"sibling":{"key":"safe"}}"#.utf8).write(
      to: url)
    try await LocalGrokCredentialWriter().persist(
      path: url.path, entryKey: "target", accessToken: "new", refreshToken: "refresh", idToken: nil,
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    XCTAssertEqual((root["target"] as? [String: Any])?["unknown"] as? String, "keep")
    XCTAssertEqual((root["sibling"] as? [String: Any])?["key"] as? String, "safe")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o600)

    let link = directory.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    do {
      try await LocalGrokCredentialWriter().persist(
        path: link.path, entryKey: "target", accessToken: "bad", refreshToken: "bad", idToken: nil,
        expiresAt: Date())
      XCTFail("Expected symbolic-link destination to be refused")
    } catch {}
  }
}

private actor ProviderFileReader: QuotaCredentialFileReading {
  let data: Data?
  init(data: Data?) { self.data = data }
  func read(path: String) -> Data? { data }
}

private struct ProviderDevinDatabase: DevinCredentialDatabaseReading {
  let value: DevinCredential?
  init(_ value: DevinCredential?) { self.value = value }
  func credential(path: String) -> DevinCredential? { value }
}

private actor ProviderGrokWriter: GrokCredentialWriting {
  private var count = 0
  func persist(
    path: String, entryKey: String, accessToken: String, refreshToken: String, idToken: String?,
    expiresAt: Date
  ) async { count += 1 }
  func persistedCount() -> Int { count }
}

private actor ProviderSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  let handler: Handler
  init(_ handler: @escaping Handler) { self.handler = handler }
  func data(for request: URLRequest) -> (Data, URLResponse) {
    let (body, status) = handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}
