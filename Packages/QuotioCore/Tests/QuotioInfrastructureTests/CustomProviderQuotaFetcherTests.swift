import Foundation
import XCTest

@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class CustomProviderQuotaFetcherTests: XCTestCase {
  func testGLMMapsQuotaSubscriptionAndUsesProviderNameInBothModes() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let repository = QuotaProviderRepository([
      CustomProvider(
        name: "Zed GLM", type: .glmCompatibility, baseURL: "https://api.z.ai/v1",
        apiKeys: [CustomAPIKeyEntry(apiKey: " glm-key ")]),
      CustomProvider(
        name: "Disabled", type: .glmCompatibility,
        apiKeys: [CustomAPIKeyEntry(apiKey: "ignored")], isEnabled: false),
    ])
    let session = QuotaRecordingSession(responses: [
      "/api/monitor/usage/quota/limit": .init(
        200,
        #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1700000000000},{"type":"TIME_LIMIT","usage":20,"currentValue":5}]}}"#
      ),
      "/api/biz/subscription/list": .init(200, #"{"data":[{"productName":" Pro "}]}"#),
    ])
    let fetcher = GLMQuotaFetcher(repository: repository, session: session, now: { date })

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(QuotaFetchRequest(provider: .glm, mode: mode))
      let quota = try XCTUnwrap(output.quotas["Zed GLM"])
      XCTAssertEqual(Set(output.quotas.keys), ["Zed GLM"])
      XCTAssertEqual(output.credentialAvailability, .present)
      XCTAssertEqual(quota.planType, "Pro")
      XCTAssertEqual(quota.lastUpdated, date)
      XCTAssertEqual(quota.models.map(\.name), ["zai-session", "zai-web-searches"])
      XCTAssertEqual(quota.models.map(\.percentage), [75, 75])
      XCTAssertEqual(quota.models[0].resetTime, "2023-11-14T22:13:20Z")
      XCTAssertEqual(quota.models[1].presentation, .progress(used: 5, limit: 20, unit: .searches))
      XCTAssertEqual(quota.models[1].used, 5)
      XCTAssertEqual(quota.models[1].limit, 20)
    }
    let requests = await session.requests()
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer  glm-key " })
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.z.ai" })
  }

  func testGLMScopesAccountsAndPreservesForbiddenQuota() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let repository = QuotaProviderRepository([
      CustomProvider(
        name: "One", type: .glmCompatibility, apiKeys: [CustomAPIKeyEntry(apiKey: "one")]),
      CustomProvider(
        name: "Two", type: .glmCompatibility, apiKeys: [CustomAPIKeyEntry(apiKey: "two")]),
    ])
    let session = QuotaRecordingSession(responses: [
      "/api/monitor/usage/quota/limit": .init(403, "denied"),
      "/api/biz/subscription/list": .init(403, "denied"),
    ])
    let fetcher = GLMQuotaFetcher(repository: repository, session: session, now: { date })

    let account = try await fetcher.fetch(
      QuotaFetchRequest(provider: .glm, scope: .account("Two"), mode: .monitor))
    XCTAssertEqual(Set(account.quotas.keys), ["Two"])
    XCTAssertEqual(account.quotas["Two"]?.isForbidden, true)
    let imported = try await fetcher.fetch(
      QuotaFetchRequest(
        provider: .glm, scope: .importedAccounts(["One"]), mode: .localProxy
      ))
    XCTAssertEqual(Set(imported.quotas.keys), ["One"])
  }

  func testGLMClassifiesTokenWindowsAndDecodesOptionalLiveFields() async throws {
    let repository = QuotaProviderRepository([
      CustomProvider(
        name: "Zed GLM", type: .glmCompatibility,
        baseURL: "https://bigmodel.cn/api/paas/v4",
        apiKeys: [CustomAPIKeyEntry(apiKey: "key")])
    ])
    let session = QuotaRecordingSession(responses: [
      "/api/monitor/usage/quota/limit": .init(
        200,
        #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":20},{"type":"TOKENS_LIMIT","unit":4,"number":1,"percentage":30},{"type":"TOKENS_LIMIT","unit":4,"number":7,"percentage":60},{"type":"TOKENS_LIMIT","unit":5,"number":1,"percentage":10},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":5},{"type":"TIME_LIMIT","usage":1000,"currentValue":0}]}}"#
      ),
      "/api/biz/subscription/list": .init(500, "unavailable"),
    ])

    let output = try await GLMQuotaFetcher(repository: repository, session: session)
      .fetch(.init(provider: .glm, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["Zed GLM"])

    XCTAssertEqual(
      quota.models.map(\.name),
      [
        "zai-session", "zai-daily", "zai-weekly", "zai-monthly", "zai-weekly",
        "zai-web-searches",
      ])
    XCTAssertEqual(quota.models.map(\.percentage), [80, 70, 40, 90, 95, 100])
    XCTAssertEqual(
      quota.models.last?.presentation,
      .progress(used: 0, limit: 1000, unit: .searches))
    let requests = await session.requests()
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "bigmodel.cn" })
  }

  func testClinePassMapsOrderedWindowsAndNormalizesResetInBothModes() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let repository = QuotaProviderRepository([
      CustomProvider(
        name: "Cline Team", type: .clinePass,
        apiKeys: [CustomAPIKeyEntry(apiKey: "  cline-key  "), CustomAPIKeyEntry(apiKey: "unused")])
    ])
    let session = QuotaRecordingSession(responses: [
      "/api/v1/users/me/plan/usage-limits": .init(
        200,
        #"{"success":true,"data":{"limits":[{"type":"monthly","percentUsed":120,"resetsAt":null},{"type":"five_hour","percentUsed":12.5,"resetsAt":"2023-11-14T22:13:20.123Z"},{"type":"weekly","percentUsed":-5,"resetsAt":"2023-11-14T22:13:20Z"},{"type":"unknown","percentUsed":1,"resetsAt":null}]}}"#
      )
    ])
    let fetcher = ClinePassQuotaFetcher(repository: repository, session: session, now: { date })

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(QuotaFetchRequest(provider: .clinePass, mode: mode))
      let quota = try XCTUnwrap(output.quotas["Cline Team"])
      XCTAssertEqual(
        quota.models.map(\.name), ["clinepass-five-hour", "clinepass-weekly", "clinepass-monthly"])
      XCTAssertEqual(quota.models.map(\.percentage), [87.5, 100, 0])
      XCTAssertEqual(quota.models[0].resetTime, "2023-11-14T22:13:20Z")
    }
    let requests = await session.requests()
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer cline-key" })
  }

  func testClinePassScopeEnabledStorageForbiddenAndMissingCredentials() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let forbiddenRepository = QuotaProviderRepository([
      CustomProvider(
        name: "Allowed", type: .clinePass, apiKeys: [CustomAPIKeyEntry(apiKey: "key")]),
      CustomProvider(
        name: "Disabled", type: .clinePass,
        apiKeys: [CustomAPIKeyEntry(apiKey: "key")], isEnabled: false),
    ])
    let session = QuotaRecordingSession(responses: [
      "/api/v1/users/me/plan/usage-limits": .init(401, "denied")
    ])
    let fetcher = ClinePassQuotaFetcher(
      repository: forbiddenRepository, session: session, now: { date })
    let output = try await fetcher.fetch(
      QuotaFetchRequest(
        provider: .clinePass, scope: .importedAccounts(["Allowed", "Disabled"]), mode: .monitor
      ))
    XCTAssertEqual(Set(output.quotas.keys), ["Allowed"])
    XCTAssertEqual(output.quotas["Allowed"]?.isForbidden, true)

    let missing = ClinePassQuotaFetcher(
      repository: QuotaProviderRepository([CustomProvider(name: "No Key", type: .clinePass)]),
      session: session
    )
    let missingOutput = try await missing.fetch(
      QuotaFetchRequest(
        provider: .clinePass, scope: .account("No Key"), mode: .localProxy
      ))
    XCTAssertTrue(missingOutput.quotas.isEmpty)
    XCTAssertEqual(missingOutput.credentialAvailability, .missing)
  }
}

private final class QuotaProviderRepository: CustomProviderRepository, @unchecked Sendable {
  private let values: [CustomProvider]
  init(_ values: [CustomProvider]) { self.values = values }
  func load() throws -> [CustomProvider] { values }
  func save(_ providers: [CustomProvider]) throws {}
}

private actor QuotaRecordingSession: QuotaHTTPSession {
  struct Response {
    let statusCode: Int
    let body: Data
    init(_ statusCode: Int, _ body: String) {
      self.statusCode = statusCode
      self.body = Data(body.utf8)
    }
  }

  private let responses: [String: Response]
  private var recorded: [URLRequest] = []
  init(responses: [String: Response]) { self.responses = responses }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(request)
    let response = try XCTUnwrap(responses[request.url!.path])
    return (
      response.body,
      HTTPURLResponse(
        url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil
      )!
    )
  }

  func requests() -> [URLRequest] { recorded }
}
