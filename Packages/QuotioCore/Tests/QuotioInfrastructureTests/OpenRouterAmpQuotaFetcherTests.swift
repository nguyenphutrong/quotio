import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class OpenRouterAmpQuotaFetcherTests: XCTestCase {
  func testOpenRouterUsesScopedVaultCredentialsAndMergesBothEndpointsInMonitorMode() async throws {
    let work = account(.openRouter, "Work")
    let other = account(.openRouter, "Other")
    let vault = FakeQuotaVault(
      accounts: [work, other], tokens: [work.id: "work-token", other.id: "other-token"])
    let session = FakeQuotaSession { request in
      if request.url?.path.hasSuffix("credits") == true {
        return (#"{"data":{"total_credits":100.25,"total_usage":40.1}}"#, 200)
      }
      return (#"{"data":{"is_free_tier":false,"usage_daily":2.5,"limit":50,"usage":10}}"#, 200)
    }
    let fetcher = OpenRouterQuotaFetcher(
      vault: vault, metadata: FakeQuotaMetadata(), session: session)

    let output = try await fetcher.fetch(
      .init(provider: .openRouter, scope: .account("Work"), mode: .monitor))
    XCTAssertEqual(Set(output.quotas.keys), ["Work"])
    XCTAssertEqual(output.credentialAvailability, .present)
    let quota = try XCTUnwrap(output.quotas["Work"])
    XCTAssertEqual(
      quota.models.first { $0.name == "openrouter-credits" }?.presentation,
      .progress(used: 40.1, limit: 100.25, unit: .usd))
    XCTAssertEqual(
      quota.models.first { $0.name == "openrouter-balance" }?.presentation,
      .amount(value: 60.15, unit: .usd, semantics: .balance))
    XCTAssertEqual(
      quota.models.first { $0.name == "openrouter-today" }?.presentation,
      .amount(value: 2.5, unit: .usd, semantics: .spent))
    XCTAssertEqual(quota.models.first { $0.name == "openrouter-key-limit" }?.percentage, 80)
    XCTAssertEqual(quota.planType, "openrouter-pay-as-you-go")
    let requests = await session.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer work-token" })
  }

  func testOpenRouterMissingCredentialAndForbiddenSemantics() async throws {
    let account = account(.openRouter, "Work")
    let missing = OpenRouterQuotaFetcher(
      vault: FakeQuotaVault(accounts: [account]), metadata: FakeQuotaMetadata(),
      session: FakeQuotaSession { _ in ("", 200) })
    let missingOutput = try await missing.fetch(.init(provider: .openRouter, mode: .monitor))
    XCTAssertEqual(missingOutput.credentialAvailability, .missing)
    XCTAssertTrue(missingOutput.quotas.isEmpty)

    let forbidden = OpenRouterQuotaFetcher(
      vault: FakeQuotaVault(accounts: [account], tokens: [account.id: "token"]),
      metadata: FakeQuotaMetadata(),
      session: FakeQuotaSession { request in
        ("denied", request.url?.path.hasSuffix("credits") == true ? 403 : 503)
      }
    )
    let local = try await forbidden.fetch(.init(provider: .openRouter, mode: .localProxy))
    let output = try await forbidden.fetch(.init(provider: .openRouter, mode: .monitor))
    XCTAssertTrue(local.quotas.isEmpty)
    XCTAssertEqual(local.credentialAvailability, .missing)
    XCTAssertEqual(output.quotas["Work"]?.isForbidden, true)
  }

  func testOpenRouterKeepsPartialCreditSuccessAndZeroFreeBalance() async throws {
    let account = account(.openRouter, "Work")
    let partial = OpenRouterQuotaFetcher(
      vault: FakeQuotaVault(accounts: [account], tokens: [account.id: "token"]),
      metadata: FakeQuotaMetadata(),
      session: FakeQuotaSession { request in
        request.url?.path.hasSuffix("credits") == true
          ? (#"{"data":{"total_credits":100.25,"total_usage":40.1}}"#, 200)
          : ("unavailable", 503)
      })

    let partialOutput = try await partial.fetch(.init(provider: .openRouter, mode: .monitor))
    XCTAssertEqual(
      partialOutput.quotas["Work"]?.models.first { $0.name == "openrouter-balance" }?
        .presentation,
      .amount(value: 60.15, unit: .usd, semantics: .balance))

    let zeroFree = OpenRouterQuotaFetcher(
      vault: FakeQuotaVault(accounts: [account], tokens: [account.id: "token"]),
      metadata: FakeQuotaMetadata(),
      session: FakeQuotaSession { request in
        request.url?.path.hasSuffix("credits") == true
          ? (#"{"data":{"total_credits":0,"total_usage":0}}"#, 200)
          : (#"{"data":{"is_free_tier":true}}"#, 200)
      })
    let zeroOutput = try await zeroFree.fetch(.init(provider: .openRouter, mode: .monitor))
    XCTAssertEqual(
      zeroOutput.quotas["Work"]?.models.first?.presentation,
      .amount(value: 0, unit: .usd, semantics: .balance))
    XCTAssertEqual(zeroOutput.quotas["Work"]?.planType, "openrouter-free")
  }

  func testAmpUsesNativeCredentialInBothModesAndVaultOnlyInMonitorMode() async throws {
    let named = account(.amp, "Amp")
    let files = FakeQuotaFileReader(
      data: Data(#"{"apiKey@https://ampcode.com/":" native-token "}"#.utf8))
    let vault = FakeQuotaVault(accounts: [named], tokens: [named.id: "named-token"])
    let session = FakeQuotaSession { request in
      let identity =
        request.value(forHTTPHeaderField: "Authorization") == "Bearer native-token"
        ? "native@example.com" : "named@example.com"
      return (
        #"{"ok":true,"result":{"displayText":"Signed in as \#(identity) (Pro)\nAmp Free: 75% remaining today (resets daily)\nAmp Megawatt Subscription: 40% agent usage and 60% orb usage remaining\nIndividual credits: $12.50 remaining\nWorkspace Acme: $8.25 remaining"}}"#,
        200
      )
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fetcher = AmpQuotaFetcher(
      vault: vault, metadata: FakeQuotaMetadata(), files: files, session: session, now: { now })

    let local = try await fetcher.fetch(.init(provider: .amp, mode: .localProxy))
    XCTAssertEqual(Set(local.quotas.keys), [AmpQuotaFetcher.localAccountKey])
    XCTAssertEqual(local.credentialAvailability, .present)
    XCTAssertEqual(
      local.quotas[AmpQuotaFetcher.localAccountKey]?.accountDisplayName, "native@example.com")

    let monitor = try await fetcher.fetch(.init(provider: .amp, mode: .monitor))
    XCTAssertEqual(Set(monitor.quotas.keys), [AmpQuotaFetcher.localAccountKey, "Amp"])
    XCTAssertEqual(monitor.credentialAvailability, .present)
    XCTAssertEqual(
      monitor.quotas["Amp"]?.models.first { $0.name == "amp-agent-usage" }?.percentage, 40)
    XCTAssertEqual(
      monitor.quotas["Amp"]?.models.first { $0.name.hasPrefix("amp-workspace-") }?.presentation,
      .amount(value: 8.25, unit: .usd, semantics: .balance))
    XCTAssertNotEqual(AmpQuotaFetcher.localAccountKey, named.accountKey)
    let paths = await files.paths()
    XCTAssertEqual(paths, [AmpQuotaFetcher.defaultNativePath, AmpQuotaFetcher.defaultNativePath])
  }

  func testAmpAccountScopeMissingForbiddenAndSecureSessionContract() async throws {
    let named = account(.amp, "Named")
    let session = FakeQuotaSession { _ in (#"{"ok":false,"error":{"code":"auth-required"}}"#, 200) }
    let fetcher = AmpQuotaFetcher(
      vault: FakeQuotaVault(accounts: [named], tokens: [named.id: "named-token"]),
      metadata: FakeQuotaMetadata(), files: FakeQuotaFileReader(data: nil), session: session
    )
    let output = try await fetcher.fetch(
      .init(provider: .amp, scope: .account("Named"), mode: .monitor))
    XCTAssertEqual(output.quotas["Named"]?.isForbidden, true)
    let recordedRequests = await session.requests()
    let request = try XCTUnwrap(recordedRequests.first)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

    let missing = AmpQuotaFetcher(
      vault: FakeQuotaVault(), metadata: FakeQuotaMetadata(), files: FakeQuotaFileReader(data: nil),
      session: session)
    let missingOutput = try await missing.fetch(.init(provider: .amp, mode: .localProxy))
    XCTAssertEqual(missingOutput.credentialAvailability, .missing)
    let configuration = AmpQuotaFetcher.sessionConfiguration()
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.urlCache)

    let delegate = AmpNoRedirectDelegate()
    let source = URL(string: "https://ampcode.com/api/internal")!
    var redirect: URLRequest? = URLRequest(url: URL(string: "https://example.com/login")!)
    delegate.urlSession(
      URLSession.shared, task: URLSession.shared.dataTask(with: source),
      willPerformHTTPRedirection: HTTPURLResponse(
        url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: redirect!
    ) { redirect = $0 }
    XCTAssertNil(redirect)
  }

  func testAmpMapsBalancesIdentityAndStableWorkspaceIDs() throws {
    let text = """
      Signed in as person@example.com (Pro)
      Amp Free: 75% remaining today (resets daily)
      Amp Megawatt Subscription: 40% agent usage and 60% orb usage remaining
      Individual credits: $12.50 remaining
      Workspace Acme: $8.25 remaining
      """
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let quota = try XCTUnwrap(AmpQuotaFetcher.parse(text, now: now))
    XCTAssertEqual(quota.accountDisplayName, "person@example.com")
    XCTAssertEqual(quota.planType, "Megawatt")
    XCTAssertEqual(quota.models.first { $0.name == "amp-free" }?.percentage, 75)
    XCTAssertFalse(try XCTUnwrap(quota.models.first { $0.name == "amp-free" }?.resetTime).isEmpty)
    XCTAssertEqual(quota.models.first { $0.name == "amp-agent-usage" }?.percentage, 40)
    XCTAssertEqual(quota.models.first { $0.name == "amp-orb-usage" }?.percentage, 60)
    let workspace = try XCTUnwrap(quota.models.first { $0.name.hasPrefix("amp-workspace-") })
    XCTAssertEqual(
      workspace.name,
      AmpQuotaFetcher.parse("Workspace Acme: $1 remaining", now: now)?.models.first?.name)
    XCTAssertEqual(
      workspace.presentation,
      .amount(value: 8.25, unit: .usd, semantics: .balance))
  }

  func testAmpMapsSubscriptionOtherUsageAndRenewalSuffix() throws {
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-11T12:00:00Z"))
    let quota = try XCTUnwrap(AmpQuotaFetcher.parse(
      "Amp Megawatt Subscription: 64% other usage and 98% orb usage remaining - resets upon renewal in 22 days",
      now: now
    ))
    let agent = try XCTUnwrap(quota.models.first { $0.name == "amp-agent-usage" })
    let orb = try XCTUnwrap(quota.models.first { $0.name == "amp-orb-usage" })
    XCTAssertEqual(quota.planType, "Megawatt")
    XCTAssertEqual(agent.percentage, 64)
    XCTAssertEqual(agent.usedPercentage, 36)
    XCTAssertEqual(agent.resetTime, "2026-09-02T12:00:00Z")
    XCTAssertEqual(orb.percentage, 98)
    XCTAssertEqual(orb.usedPercentage, 2)
    XCTAssertEqual(orb.resetTime, "2026-09-02T12:00:00Z")
  }

  func testAmpMapsRealBalanceOutputWithFreeAndSubscription() throws {
    let text = """
      Signed in as person@example.com (trng)
      Amp Free: 0% remaining today (resets daily) - https://ampcode.com/settings#amp-free
      Amp Megawatt Subscription: 100% other usage and 100% orb usage remaining - resets upon renewal in 1 month
      Individual credits: $21.57 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings

      Run amp usage --details for more detailed information.
      """
    let quota = try XCTUnwrap(AmpQuotaFetcher.parse(text, now: Date(timeIntervalSince1970: 1_700_000_000)))
    XCTAssertEqual(quota.planType, "Megawatt")
    XCTAssertEqual(
      quota.models.map(\.name),
      ["amp-agent-usage", "amp-orb-usage", "amp-free", "amp-individual-credits"])
    XCTAssertEqual(quota.models.first { $0.name == "amp-free" }?.percentage, 0)
    XCTAssertEqual(quota.models.first { $0.name == "amp-agent-usage" }?.percentage, 100)
    XCTAssertEqual(quota.models.first { $0.name == "amp-orb-usage" }?.percentage, 100)
    XCTAssertEqual(
      quota.models.first { $0.name == "amp-individual-credits" }?.presentation,
      .amount(value: 21.57, unit: .usd, semantics: .balance))
  }

  func testAmpUsesIdentityPlanWhenSubscriptionIsMissing() throws {
    let quota = try XCTUnwrap(AmpQuotaFetcher.parse(
      """
      Signed in as person@example.com (Pro)
      Amp Free: 75% remaining today (resets daily)
      """,
      now: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    XCTAssertEqual(quota.accountDisplayName, "person@example.com")
    XCTAssertEqual(quota.planType, "Pro")
  }

  func testAmpMapsDollarFreeQuota() throws {
    let quota = try XCTUnwrap(AmpQuotaFetcher.parse(
      "Amp Free: $5/$20 remaining (replenishes +$1/hour)",
      now: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    XCTAssertEqual(quota.models.first?.percentage, 25)
    XCTAssertEqual(
      quota.models.first?.presentation,
      .progress(used: 15, limit: 20, unit: .usd))
  }

  private func account(_ provider: QuotaProvider, _ key: String) -> Account {
    Account.make(
      providerID: .init(rawValue: provider.rawValue), accountKey: key, source: .quotioKeychain)
  }
}

private actor FakeQuotaSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private var recorded: [URLRequest] = []
  init(handler: @escaping Handler) { self.handler = handler }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(request)
    let (body, status) = handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
  func requests() -> [URLRequest] { recorded }
}

private actor FakeQuotaFileReader: QuotaCredentialFileReading {
  private let data: Data?
  private var readPaths: [String] = []
  init(data: Data?) { self.data = data }
  func read(path: String) -> Data? {
    readPaths.append(path)
    return data
  }
  func paths() -> [String] { readPaths }
}

private actor FakeQuotaVault: CredentialVault {
  private let storedAccounts: [Account]
  private let tokens: [String: String]
  init(accounts: [Account] = [], tokens: [String: String] = [:]) {
    storedAccounts = accounts
    self.tokens = tokens
  }
  func accounts() -> [Account] { storedAccounts }
  func credential(for accountID: String) -> StoredCredential? {
    tokens[accountID].map {
      StoredCredential(
        accessToken: $0, refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:]
      )
    }
  }
  func reloadLatest(accountID: String) -> StoredCredential? { credential(for: accountID) }
  func save(_ credential: StoredCredential, metadata: Account) throws {}
  func delete(accountID: String) {}
}

private actor FakeQuotaMetadata: AccountMetadataRepository {
  private let disabled: Set<String>
  init(disabled: Set<String> = []) { self.disabled = disabled }
  func accounts() -> [Account] { [] }
  func disabledAccountIDs() -> Set<String> { disabled }
  func saveAccount(_ account: Account) throws {}
  func deleteAccount(_ accountID: String) throws {}
  func setDisabled(_ disabled: Bool, accountID: String) throws {}
}
