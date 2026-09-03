import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3
import XCTest

@testable import QuotioInfrastructure

final class CursorTraeQuotaFetcherTests: XCTestCase {
  func testCursorReadsLegacyDatabaseKeysWithoutMutatingDatabase() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state with spaces.vscdb").path
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        database,
        "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','token'),('cursorAuth/cachedEmail','cursor@example.com'),('cursorAuth/stripeMembershipType','pro_student'),('unrelated','keep');",
        nil, nil, nil), SQLITE_OK)
    sqlite3_close(database)

    XCTAssertEqual(
      LocalCursorCredentialDatabaseReader().credential(path: path),
      CursorCredential(
        accessToken: "token", email: "cursor@example.com", membershipType: "pro_student",
        subscriptionStatus: nil))
  }

  func testCursorIsImportedOnlyScopesAccountAndPreservesRequestAndMappingInBothModes() async throws
  {
    let session = IDESession { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api2.cursor.sh/auth/usage-summary")
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
      return (
        #"{"membershipType":"pro_student","billingCycleEnd":"2030-01-02T03:04:05.000Z","individualUsage":{"plan":{"enabled":true,"used":20,"limit":100,"remaining":80},"onDemand":{"enabled":true,"used":4,"limit":10,"remaining":6}}}"#,
        200
      )
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fetcher = CursorQuotaFetcher(
      database: CursorDatabase(
        .init(
          accessToken: "cursor-token", email: "cursor@example.com", membershipType: "free",
          subscriptionStatus: "active")), applications: InstalledIDE(), session: session,
      now: { now })

    let automatic = try await fetcher.fetch(.init(provider: .cursor, mode: .monitor))
    XCTAssertTrue(automatic.quotas.isEmpty)
    let automaticRequestCount = await session.requestCount()
    XCTAssertEqual(
      automaticRequestCount, 0, "Provider-wide auto refresh must not read imported IDE credentials")

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .cursor, scope: .importedAccounts(["cursor@example.com"]), mode: mode))
      XCTAssertEqual(output.credentialAvailability, .present)
      XCTAssertEqual(output.quotas["cursor@example.com"]?.planType, "Pro Student")
      XCTAssertEqual(
        output.quotas["cursor@example.com"]?.models.map(\.name), ["plan-usage", "on-demand"])
      XCTAssertEqual(output.quotas["cursor@example.com"]?.models[0].percentage, 80)
      XCTAssertEqual(output.quotas["cursor@example.com"]?.models[1].percentage, 60)
    }
    let excluded = try await fetcher.fetch(
      .init(provider: .cursor, scope: .account("deleted@example.com"), mode: .monitor))
    XCTAssertTrue(excluded.quotas.isEmpty)
  }

  func testCursorForcedProviderScanAndCorruptResponseUseLocalIdentityFallback() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fetcher = CursorQuotaFetcher(
      database: CursorDatabase(
        .init(accessToken: "token", email: nil, membershipType: "pro", subscriptionStatus: nil)),
      applications: InstalledIDE(), session: IDESession { _ in ("not-json", 200) }, now: { now })
    let output = try await fetcher.fetch(.init(provider: .cursor, mode: .monitor, force: true))
    XCTAssertEqual(output.quotas.keys.sorted(), ["Cursor User"])
    XCTAssertEqual(output.quotas["Cursor User"]?.models.first?.name, "cursor-usage")
    XCTAssertEqual(output.quotas["Cursor User"]?.planType, "Pro")
  }

  func testTraeParsesNestedLegacyCredentialAndRejectsCorruptData() {
    let data = Data(
      #"{"iCubeAuthInfo://icube.cloudide":"{\"token\":\"jwt\",\"refreshToken\":\"refresh\",\"userId\":\"42\",\"host\":\"https://host.test\",\"account\":{\"email\":\"trae@example.com\",\"username\":\"trae-user\"}}"}"#
        .utf8)
    XCTAssertEqual(
      TraeQuotaFetcher.parseCredential(data),
      TraeCredential(
        accessToken: "jwt", email: "trae@example.com", userID: "42", apiHost: "https://host.test",
        username: "trae-user"))
    XCTAssertNil(TraeQuotaFetcher.parseCredential(Data("corrupt".utf8)))
  }

  func testTraeIsImportedOnlyPreservesRequestAccountPriorityAndMappingInBothModes() async throws {
    let credential = Data(
      #"{"iCubeAuthInfo://icube.cloudide":"{\"token\":\"jwt\",\"userId\":\"42\",\"host\":\"https://host.test\",\"account\":{\"email\":\"trae@example.com\",\"username\":\"fallback\"}}"}"#
        .utf8)
    let session = IDESession { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://host.test/trae/api/v1/pay/user_current_entitlement_list")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Cloud-IDE-JWT jwt")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://www.trae.ai")
      XCTAssertEqual(
        (try! JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Bool])?[
          "require_usage"], true)
      return (
        #"{"user_entitlement_pack_list":[{"status":1,"entitlement_base_info":{"end_time":1893456000,"product_type":1,"quota":{"premium_model_fast_request_limit":100,"premium_model_slow_request_limit":50,"advanced_model_request_limit":20,"auto_completion_limit":10}},"usage":{"premium_model_fast_amount":25,"premium_model_slow_amount":10,"advanced_model_amount":5,"auto_completion_amount":1}}]}"#,
        200
      )
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fetcher = TraeQuotaFetcher(
      files: IDEFileReader(credential), applications: InstalledIDE(), session: session, now: { now }
    )
    let automatic = try await fetcher.fetch(.init(provider: .trae, mode: .localProxy))
    XCTAssertTrue(automatic.quotas.isEmpty)
    let automaticRequestCount = await session.requestCount()
    XCTAssertEqual(automaticRequestCount, 0)

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .trae, scope: .account("trae@example.com"), mode: mode))
      let quota = try XCTUnwrap(output.quotas["trae@example.com"])
      XCTAssertEqual(quota.planType, "Pro")
      XCTAssertEqual(
        quota.models.map(\.name),
        ["premium-fast", "premium-slow", "advanced-model", "auto-completion"])
      XCTAssertEqual(quota.models.map(\.remaining), [75, 40, 15, 9])
    }
    let deleted = try await fetcher.fetch(
      .init(provider: .trae, scope: .importedAccounts([]), mode: .monitor))
    XCTAssertTrue(deleted.quotas.isEmpty)
  }

  func testMissingApplicationOrCorruptCredentialDoesNotPerformNetworkIO() async throws {
    let session = IDESession { _ in
      XCTFail("Unexpected request")
      return ("", 500)
    }
    let cursor = CursorQuotaFetcher(
      database: CursorDatabase(
        .init(accessToken: "token", email: "a", membershipType: nil, subscriptionStatus: nil)),
      applications: MissingIDE(), session: session)
    let trae = TraeQuotaFetcher(
      files: IDEFileReader(Data("corrupt".utf8)), applications: InstalledIDE(), session: session)
    let cursorOutput = try await cursor.fetch(
      .init(provider: .cursor, scope: .account("a"), mode: .monitor))
    let traeOutput = try await trae.fetch(
      .init(provider: .trae, scope: .account("a"), mode: .monitor))
    let requestCount = await session.requestCount()
    XCTAssertEqual(cursorOutput.credentialAvailability, .missing)
    XCTAssertEqual(traeOutput.credentialAvailability, .missing)
    XCTAssertEqual(requestCount, 0)
  }
}

private struct CursorDatabase: CursorCredentialDatabaseReading {
  let value: CursorCredential?
  init(_ value: CursorCredential?) { self.value = value }
  func credential(path: String) -> CursorCredential? { value }
}
private struct InstalledIDE: IDEApplicationChecking {
  func isInstalled(paths: [String]) -> Bool { true }
}
private struct MissingIDE: IDEApplicationChecking {
  func isInstalled(paths: [String]) -> Bool { false }
}
private actor IDEFileReader: QuotaCredentialFileReading {
  let data: Data?
  init(_ data: Data?) { self.data = data }
  func read(path: String) -> Data? { data }
}
private actor IDESession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private var count = 0
  init(_ handler: @escaping Handler) { self.handler = handler }
  func data(for request: URLRequest) -> (Data, URLResponse) {
    count += 1
    let (body, status) = handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
  func requestCount() -> Int { count }
}
