import Foundation
import XCTest

@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class WarpQuotaFetcherTests: XCTestCase {
  func testRepositoryReadsAndWritesLegacySchemaAtExistingKey() async throws {
    let suite = "WarpQuotaFetcherTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let id = UUID(uuidString: "1D34A269-9957-4BA9-85D2-C42A65045BB9")!
    defaults.set(
      Data(
        #"[{"id":"1D34A269-9957-4BA9-85D2-C42A65045BB9","name":"Work","token":"secret","isEnabled":false}]"#
          .utf8), forKey: "warpTokens")
    let repository = UserDefaultsWarpTokenRepository(defaults: defaults)

    let loadedTokens = try await repository.load()
    XCTAssertEqual(
      loadedTokens,
      [WarpToken(id: id, name: "Work", token: "secret", isEnabled: false)])
    try await repository.save([WarpToken(id: id, name: "Personal", token: "new", isEnabled: true)])
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: defaults.data(forKey: "warpTokens")!) as? [[String: Any]])
    XCTAssertEqual(object.first?["id"] as? String, id.uuidString)
    XCTAssertEqual(object.first?["name"] as? String, "Personal")
    XCTAssertEqual(object.first?["token"] as? String, "new")
    XCTAssertEqual(object.first?["isEnabled"] as? Bool, true)
  }

  func testProviderScopeFiltersDisabledTokensAndMapsRequestAndResponse() async throws {
    let repository = StubWarpTokenRepository(tokens: [
      WarpToken(name: "Work", token: "work-token"),
      WarpToken(name: "Disabled", token: "disabled-token", isEnabled: false),
    ])
    let session = RecordingWarpSession(body: Self.successBody)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fetcher = WarpQuotaFetcher(repository: repository, session: session, now: { now })

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(QuotaFetchRequest(provider: .warp, mode: mode))
      XCTAssertEqual(Set(output.quotas.keys), ["Work"])
      XCTAssertEqual(output.credentialAvailability, .present)
      let quota = try XCTUnwrap(output.quotas["Work"])
      XCTAssertEqual(quota.lastUpdated, now)
      XCTAssertEqual(
        quota.models.first,
        QuotaMetric(
          name: "warp-usage", percentage: 75, resetTime: "2026-01-02T03:04:05Z", used: 25,
          limit: 100, remaining: 75))
      XCTAssertEqual(quota.models.last?.name, "warp-bonus-0")
      XCTAssertEqual(quota.models.last?.percentage, 50)
      XCTAssertEqual(quota.models.last?.resetTime, "2026-02-03T04:05:06Z")
    }
    let requests = await session.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer work-token" })
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "x-warp-client-id") == "warp-app" })
    let body =
      try JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first?.httpBody))
      as? [String: Any]
    XCTAssertEqual(body?["operationName"] as? String, "GetRequestLimitInfo")
  }

  func testAccountScopeUsesTokenNameAndMapsForbidden() async throws {
    let repository = StubWarpTokenRepository(tokens: [
      WarpToken(name: "Work", token: "work-token"),
      WarpToken(name: "Personal", token: "personal-token"),
    ])
    let session = RecordingWarpSession(body: "denied", statusCode: 403)
    let fetcher = WarpQuotaFetcher(repository: repository, session: session)

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        QuotaFetchRequest(provider: .warp, scope: .account("Personal"), mode: mode))
      XCTAssertEqual(Set(output.quotas.keys), ["Personal"])
      XCTAssertEqual(output.quotas["Personal"]?.isForbidden, true)
    }
    let requests = await session.requests()
    XCTAssertTrue(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer personal-token"
      })
  }

  private static let successBody =
    #"{"data":{"user":{"user":{"requestLimitInfo":{"isUnlimited":false,"nextRefreshTime":"2026-01-02T03:04:05.123Z","requestLimit":100,"requestsUsedSinceLastRefresh":25},"workspaces":[{"bonusGrantsInfo":{"grants":[{"expiration":"2026-02-03T04:05:06.000Z","userFacingMessage":"Bonus grant.","requestCreditsGranted":20,"requestCreditsRemaining":10}]}}],"bonusGrants":[]}}}}"#
}

private struct StubWarpTokenRepository: WarpTokenRepository {
  let tokens: [WarpToken]
  func load() async throws -> [WarpToken] { tokens }
  func save(_ tokens: [WarpToken]) async throws {}
}

private actor RecordingWarpSession: QuotaHTTPSession {
  private let body: Data
  private let statusCode: Int
  private var recorded: [URLRequest] = []

  init(body: String, statusCode: Int = 200) {
    self.body = Data(body.utf8)
    self.statusCode = statusCode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(request)
    return (
      body,
      HTTPURLResponse(
        url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    )
  }

  func requests() -> [URLRequest] { recorded }
}
