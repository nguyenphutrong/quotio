import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class MuseQuotaFetcherTests: XCTestCase {
  /// Shaped like the auth file CLIProxyAPI writes after a Meta login, including the
  /// Model API key this fetcher must leave alone.
  private static let authFile = """
    {"type":"meta","auth_kind":"oauth","access_token":"LLM|1234567890|key-material",
    "api_key":"LLM|1234567890|key-material","dca_token":"dca:account-token",
    "base_url":"https://api.meta.ai/v1","email":"Developer@Example.test","name":"Developer"}
    """
  private static let keyResponse = """
    {"api_key":"LLM|1234567890|key-material","is_subs_active":true,
    "subs_tier_name":"Muse Code Pro","user_email":"developer@example.test",
    "subs_usage":{"window":{"used_percent":12,"resets_at":1788431188,"window_duration_mins":300},
    "weekly":{"used_percent":40,"resets_at":1788739200}}}
    """

  func testReadsTheProxyAuthFileAndIgnoresTheModelAPIKeyBesideTheAccountToken() {
    let credential = MuseQuotaFetcher.credential(from: Data(Self.authFile.utf8))

    XCTAssertEqual(credential?.accountKey, "developer@example.test")
    XCTAssertEqual(credential?.displayName, "developer@example.test")
    XCTAssertEqual(credential?.dcaToken, "dca:account-token")
  }

  /// A file carrying only the Model API key is not an account this fetcher can read:
  /// that key authenticates model calls and is refused by the subscription endpoint.
  func testAnAuthFileWithoutADCATokenIsNotAnAccount() {
    XCTAssertNil(
      MuseQuotaFetcher.credential(
        from: Data(#"{"type":"meta","api_key":"LLM|1|k","access_token":"LLM|1|k"}"#.utf8)))
    XCTAssertNil(MuseQuotaFetcher.credential(from: Data("not json".utf8)))
  }

  func testAnAuthFileWithoutAnEmailStillYieldsOneAccount() {
    let credential = MuseQuotaFetcher.credential(
      from: Data(#"{"type":"meta","dca_token":"dca:account-token"}"#.utf8))

    XCTAssertEqual(credential?.accountKey, MuseQuotaFetcher.localAccountKey)
    XCTAssertNil(credential?.displayName)
  }

  func testOnlyMetaFilesInTheAuthDirectoryAreRead() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(Self.authFile.utf8)
      .write(to: directory.appendingPathComponent("meta-developer-1234.json"))
    try Data(Self.authFile.utf8)
      .write(to: directory.appendingPathComponent("claude-someone.json"))
    try Data(#"{"type":"meta","api_key":"LLM|1|k"}"#.utf8)
      .write(to: directory.appendingPathComponent("meta-broken.json"))

    let credentials = MuseQuotaFetcher.loadCredentials(directory: directory.path)

    XCTAssertEqual(credentials.map(\.accountKey), ["developer@example.test"])
  }

  func testSendsTheAccountTokenAndReportsBothWindowsAsRemainingPercentages() async throws {
    let session = MuseSession { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/muse-code/key")
      XCTAssertEqual(request.httpMethod, "POST")
      // The DCA token travels as the bearer and in the body, under Meta's client UA:
      // the same shape CLIProxyAPI uses to mint the key.
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"), "Bearer dca:account-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "muse-code/1.0.2")
      let sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
      XCTAssertEqual(sent as? [String: String], ["dca_token": "dca:account-token"])
      return (Self.keyResponse, 200)
    }
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile), session: session,
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .present)
    XCTAssertEqual(output.credentialAccountKeys, ["developer@example.test"])
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])
    XCTAssertEqual(quota.planType, "Muse Code Pro")
    let session5h = try XCTUnwrap(quota.models.first { $0.name == "muse-session" })
    XCTAssertEqual(session5h.percentage, 88)
    XCTAssertEqual(
      ISO8601DateFormatter().date(from: session5h.resetTime),
      Date(timeIntervalSince1970: 1_788_431_188))
    XCTAssertEqual(quota.models.first { $0.name == "muse-weekly" }?.percentage, 60)
  }

  func testNeverCarriesTheModelAPIKeyOutOfTheResponse() async throws {
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile),
      session: MuseSession { _ in (Self.keyResponse, 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])

    let rendered =
      [quota.planType, quota.accountDisplayName].compactMap { $0 }
      + quota.models.flatMap { [$0.name, $0.resetTime] }
    for value in rendered {
      XCTAssertFalse(value.contains("LLM|"), "leaked the Model API key in \(value)")
      XCTAssertFalse(value.contains("key-material"), "leaked the Model API key in \(value)")
    }
  }

  func testCarriesAWindowOfAnotherDurationUnderItsOwnNameInsteadOfTheSessionSlot() {
    let quota = MuseQuotaFetcher.mapUsage(
      ["window": ["used_percent": 25, "resets_at": 1_788_431_188, "window_duration_mins": 600]],
      plan: nil, displayName: nil, now: Date(timeIntervalSince1970: 1_788_000_000))

    XCTAssertEqual(quota.models.map(\.name), ["muse-window-600", "muse-weekly"])
    XCTAssertEqual(quota.models.first?.percentage, 75)
  }

  /// Reproduces the real response of an active subscription, measured live 2026-09-16:
  /// `is_subs_active: true` with no `subs_usage` at all. Both windows must still be
  /// reported, as unknown rather than as a fetch failure.
  func testAnActiveSubscriptionWithNoSubsUsageReportsUnknownWindowsNotAFailure() async throws {
    let body = """
      {"is_subs_active":true,"subs_tier_name":"Muse Code High Usage",
      "user_email":"developer@example.test"}
      """
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile),
      session: MuseSession { _ in (body, 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])

    XCTAssertEqual(quota.planType, "Muse Code High Usage")
    XCTAssertEqual(quota.models.map(\.name), ["muse-session", "muse-weekly"])
    XCTAssertTrue(quota.models.allSatisfy { $0.percentage < 0 })
  }

  func testInactiveSubscriptionReportsAStatusInsteadOfInventedWindows() async throws {
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile),
      session: MuseSession { _ in
        (#"{"is_subs_active":false,"subs_tier_name":"Muse Code Free"}"#, 200)
      },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])

    XCTAssertEqual(quota.planType, "Muse Code Free")
    XCTAssertEqual(quota.models.map(\.presentation), [.status(text: "muse-inactive")])
  }

  func testRejectedCredentialMarksTheAccountForbiddenRatherThanEmpty() async throws {
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile),
      session: MuseSession { _ in (#"{"error":"invalid_api_key"}"#, 401) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.quotas["developer@example.test"]?.isForbidden, true)
  }

  func testNoAuthFileReportsTheCredentialAsMissing() async throws {
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(nil),
      session: MuseSession { _ in XCTFail("no request without a credential"); return ("", 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .missing)
    XCTAssertEqual(output.credentialAccountKeys, [])
  }

  func testAnotherAccountInScopeIsNotFetched() async throws {
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile),
      session: MuseSession { _ in XCTFail("out of scope"); return ("", 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(
      .init(provider: .muse, scope: .account("someone-else@example.test"), mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .present)
    XCTAssertTrue(output.quotas.isEmpty)
  }

  func testAForcedRefreshInsideTheWindowServesTheLastReadWithoutSpendingAKeyRequest()
    async throws
  {
    let clock = MuseClock(Date(timeIntervalSince1970: 1_788_000_000))
    let session = MuseSession { _ in (Self.keyResponse, 200) }
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile), session: session, now: { clock.date })

    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    clock.advance(MuseQuotaFetcher.refreshInterval - 1)
    let cached = try await fetcher.fetch(.init(provider: .muse, mode: .monitor, force: true))
    let afterCache = await session.count()
    XCTAssertEqual(afterCache, 1)
    XCTAssertNotNil(cached.quotas["developer@example.test"])

    clock.advance(2)
    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let afterWindow = await session.count()
    XCTAssertEqual(afterWindow, 2)
  }

  /// With nothing read yet there is no reading to fall back on, and an empty answer
  /// would be taken for a successful refresh: the account would show neither a quota nor
  /// a reason until the backoff elapsed.
  func testAFirstReadThatFailsIsReportedRatherThanReturnedEmpty() async {
    let session = MuseSession { _ in (Self.keyResponse, 200) }
    await session.fail(true)
    let fetcher = MuseQuotaFetcher(credentials: MuseSource(Self.authFile), session: session)

    do {
      let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
      XCTFail("expected the failure to travel up, got \(output.quotas)")
    } catch {}
  }

  func testAFailureBacksOffAndKeepsServingTheLastGoodReading() async throws {
    let clock = MuseClock(Date(timeIntervalSince1970: 1_788_000_000))
    let session = MuseSession { _ in (Self.keyResponse, 200) }
    let fetcher = MuseQuotaFetcher(
      credentials: MuseSource(Self.authFile), session: session, now: { clock.date })

    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    clock.advance(MuseQuotaFetcher.refreshInterval)
    await session.fail(true)
    let backedOff = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    XCTAssertNotNil(backedOff.quotas["developer@example.test"], "the last reading is kept")

    clock.advance(MuseQuotaFetcher.failureBackoff - 1)
    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor, force: true))
    let stillTwo = await session.count()
    XCTAssertEqual(stillTwo, 2, "a forced refresh must not spend a key request")
  }

  /// The vault is the store Quotio owns, exactly as every other provider uses it, and it
  /// is consulted only in monitor mode — in local-proxy mode the proxy holds the account.
  func testMonitorModePrefersTheVaultAndLocalProxyModeDoesNotTouchIt() async {
    let vault = MuseVault(accountKey: "vaulted@example.test", token: "vault-token")
    let source = CompositeMuseCredentialSource(
      local: MuseSource(Self.authFile), vault: vault, metadata: MuseMetadata())

    let monitor = await source.credentials(for: .monitor)
    XCTAssertEqual(
      monitor.map(\.accountKey), ["vaulted@example.test", "developer@example.test"])
    XCTAssertEqual(monitor.first?.dcaToken, "vault-token")

    let proxy = await source.credentials(for: .localProxy)
    XCTAssertEqual(proxy.map(\.accountKey), ["developer@example.test"])
  }

  func testAnAccountInBothStoresIsReadOnceFromTheVault() async {
    let vault = MuseVault(accountKey: "developer@example.test", token: "vault-token")
    let source = CompositeMuseCredentialSource(
      local: MuseSource(Self.authFile), vault: vault, metadata: MuseMetadata())

    let monitor = await source.credentials(for: .monitor)

    XCTAssertEqual(monitor.map(\.accountKey), ["developer@example.test"])
    XCTAssertEqual(monitor.first?.dcaToken, "vault-token")
  }
}

private struct MuseSource: MuseCredentialSourcing {
  let payload: String?
  init(_ payload: String?) { self.payload = payload }
  func credentials(for mode: QuotaOperatingMode) async -> [MuseQuotaFetcher.Credential] {
    payload.flatMap { MuseQuotaFetcher.credential(from: Data($0.utf8)) }.map { [$0] } ?? []
  }
}

private actor MuseVault: CredentialVault {
  private let account: Account
  private let token: String

  init(accountKey: String, token: String) {
    account = Account.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.muse.rawValue),
      accountKey: accountKey,
      displayName: accountKey,
      source: .quotioKeychain
    )
    self.token = token
  }

  func accounts() async -> [Account] { [account] }
  func credential(for accountID: String) async -> StoredCredential? {
    guard accountID == account.id else { return nil }
    return StoredCredential(
      accessToken: token, refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil,
      extra: [:])
  }
  func reloadLatest(accountID: String) async -> StoredCredential? { nil }
  func save(_ credential: StoredCredential, metadata: Account) async throws {}
  func delete(accountID: String) async {}
}

private actor MuseMetadata: AccountMetadataRepository {
  func accounts() async -> [Account] { [] }
  func disabledAccountIDs() async -> Set<String> { [] }
  func saveAccount(_ account: Account) async throws {}
  func deleteAccount(_ accountID: String) async throws {}
  func setDisabled(_ disabled: Bool, accountID: String) async throws {}
}

private actor MuseSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private var requests = 0
  private var failing = false

  init(_ handler: @escaping Handler) { self.handler = handler }
  func count() -> Int { requests }
  func fail(_ value: Bool) { failing = value }

  func data(for request: URLRequest) -> (Data, URLResponse) {
    requests += 1
    let (body, status) = failing ? ("", 429) : handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}

private final class MuseClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var date: Date { lock.withLock { value } }
  func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
}
