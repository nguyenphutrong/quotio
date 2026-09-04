import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class CopilotKiroQuotaFetcherTests: XCTestCase {
  func testCopilotPreservesIdentityScopeHeadersMappingsAndForbiddenInBothModes() async throws {
    let source = CopilotTestSource([
      .init(accessToken: "good", canonicalKey: "octocat", aliases: ["github-copilot-octocat.json"]),
      .init(accessToken: "denied", canonicalKey: "denied"),
    ])
    let session = AdapterTestSession { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer denied" { return ("", 403) }
      return (
        #"{"access_type_sku":"copilot_for_individual","copilot_plan":"individual","quota_reset_date_utc":"2030-02-01T00:00:00Z","quota_snapshots":{"chat":{"remaining":25,"entitlement":50},"completions":{"unlimited":true},"premium_interactions":{"percent_remaining":37}}}"#,
        200
      )
    }
    let fetcher = CopilotQuotaFetcher(
      vault: AdapterTestVault(), metadata: AdapterTestMetadata(), credentials: source,
      session: session, now: { Date(timeIntervalSince1970: 10) })

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .copilot, scope: .account("github-copilot-octocat.json"), mode: mode))
      XCTAssertEqual(output.credentialAvailability, .present)
      XCTAssertEqual(Set(output.quotas.keys), ["octocat"])
      XCTAssertEqual(output.accountAliases["github-copilot-octocat.json"], "octocat")
      XCTAssertEqual(output.quotas["octocat"]?.planType, "Pro")
      XCTAssertEqual(
        output.quotas["octocat"]?.models.map(\.name), ["copilot-chat", "copilot-premium"])
      XCTAssertEqual(output.quotas["octocat"]?.models.first?.percentage, 50)
      XCTAssertEqual(output.quotas["octocat"]?.models.first?.resetTime, "2030-02-01T00:00:00Z")
    }
    let denied = try await fetcher.fetch(
      .init(provider: .copilot, scope: .account("denied"), mode: .monitor))
    XCTAssertEqual(denied.quotas["denied"]?.isForbidden, true)
  }

  func testCopilotLocalSourcePreservesCanonicalPrecedenceAndNativePaths() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".cli-proxy-api"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".config/github-copilot"), withIntermediateDirectories: true)
    try Data(
      #"{"access_token":"proxy","username":"preferred","login":"legacy","unknown":"keep"}"#.utf8
    ).write(to: home.appendingPathComponent(".cli-proxy-api/github-copilot-filename.json"))
    try Data(#"{"github.com":{"oauth_token":"native"}}"#.utf8).write(
      to: home.appendingPathComponent(".config/github-copilot/hosts.json"))
    let values = await LocalCopilotQuotaCredentialSource(homeDirectory: home.path).credentials()
    XCTAssertEqual(values.first { $0.accessToken == "proxy" }?.canonicalKey, "preferred")
    XCTAssertEqual(
      values.first { $0.accessToken == "proxy" }?.aliases,
      ["github-copilot-filename.json", "github-copilot-filename", "filename"])
    XCTAssertEqual(
      values.first { $0.accessToken == "native" }?.canonicalKey,
      CopilotQuotaFetcher.nativeAccountKey)
  }

  func testCopilotVaultCredentialsAreVisibleOnlyInMonitorMode() async throws {
    let account = Account.make(
      providerID: .init(rawValue: QuotaProvider.copilot.rawValue), accountKey: "vault-user",
      source: .quotioKeychain)
    let credential = StoredCredential(
      accessToken: "vault-token", refreshToken: nil, idToken: nil, accountID: nil,
      expiresAt: nil, extra: [:])
    let fetcher = CopilotQuotaFetcher(
      vault: AdapterTestVault(accounts: [account], credentials: [account.id: credential]),
      metadata: AdapterTestMetadata(), credentials: CopilotTestSource([]),
      session: AdapterTestSession { _ in
        (#"{"copilot_plan":"individual","quota_snapshots":{"chat":{"remaining":25,"entitlement":50}}}"#, 200)
      }
    )

    let local = try await fetcher.fetch(.init(provider: .copilot, mode: .localProxy))
    let monitor = try await fetcher.fetch(.init(provider: .copilot, mode: .monitor))

    XCTAssertTrue(local.quotas.isEmpty)
    XCTAssertEqual(local.credentialAvailability, .missing)
    XCTAssertNotNil(monitor.quotas["vault-user"])
  }

  func testCopilotAvailableModelCatalogPreservesExchangeAndAvailabilityFiltering() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".cli-proxy-api"), withIntermediateDirectories: true)
    try Data(#"{"access_token":"github-token"}"#.utf8).write(
      to: home.appendingPathComponent(".cli-proxy-api/github-copilot-person.json"))
    let session = AdapterTestSession { request in
      if request.url?.host == "api.github.com" {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        return (#"{"token":"copilot-token"}"#, 200)
      }
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer copilot-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.100.0")
      return (
        #"{"data":[{"id":"enabled","model_picker_enabled":true},{"id":"hidden","model_picker_enabled":false}]}"#,
        200
      )
    }
    let catalog = CopilotAvailableModelCatalog(homeDirectory: home.path, session: session)

    let models = await catalog.availableModelIDs()

    XCTAssertEqual(models, ["enabled"])
  }

  func testKiroScopesBothModesUsesRegionHeadersAndMapsSemanticValues() async throws {
    let credential = KiroQuotaCredential(
      accessToken: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
      profileARN: "arn:aws:codewhisperer:ap-northeast-2:123:profile/test",
      accountKey: "person@example.com")
    let source = KiroTestSource([credential])
    let session = AdapterTestSession { request in
      XCTAssertEqual(request.url?.host, "q.ap-northeast-2.amazonaws.com")
      XCTAssertEqual(request.url?.query?.contains("origin=AI_EDITOR"), true)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "amz-sdk-request"), "attempt=1; max=1")
      XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasSuffix("-machine-id") == true)
      XCTAssertTrue(
        request.value(forHTTPHeaderField: "x-amz-user-agent")?.hasSuffix("-machine-id") == true)
      return (
        #"{"nextDateReset":1900000000,"subscriptionInfo":{"subscriptionTitle":"Kiro Pro"},"usageBreakdownList":[{"displayName":"Agentic requests","resourceType":"AGENTIC_REQUEST","currentUsageWithPrecision":20,"usageLimitWithPrecision":100,"freeTrialInfo":{"currentUsage":5,"usageLimit":10,"freeTrialStatus":"ACTIVE","freeTrialExpiry":1800000000}}]}"#,
        200
      )
    }
    let fetcher = KiroQuotaFetcher(
      vault: AdapterTestVault(), metadata: AdapterTestMetadata(), credentials: source,
      session: session, now: { Date(timeIntervalSince1970: 1_700_000_000) },
      machineIdentifier: { _ in "machine-id" })
    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .kiro, scope: .account("person@example.com"), mode: mode))
      let quota = try XCTUnwrap(output.quotas["person@example.com"])
      XCTAssertEqual(quota.planType, "Kiro Pro")
      XCTAssertEqual(
        quota.models.map(\.name), ["kiro-bonus-AGENTIC_REQUEST", "kiro-AGENTIC_REQUEST"])
      XCTAssertEqual(quota.models.map(\.percentage), [50, 80])
      XCTAssertEqual(quota.models.last?.used, 20)
      XCTAssertTrue(quota.models.last?.resetTime.contains("T") == true)
    }
  }

  func testKiroRejectsMalformedCredentialRegionWithoutConstructingARequest() async throws {
    let credentials = [
      KiroQuotaCredential(
        accessToken: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        region: "us east 1", accountKey: "person@example.com"),
      KiroQuotaCredential(
        accessToken: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        profileARN: "arn:aws:codewhisperer:us east 1:123:profile/test",
        accountKey: "other@example.com"),
    ]
    let fetcher = KiroQuotaFetcher(
      vault: AdapterTestVault(), metadata: AdapterTestMetadata(),
      credentials: KiroTestSource(credentials),
      session: AdapterTestSession { _ in (#"{"usageBreakdownList":[]}"#, 200) },
      now: { Date(timeIntervalSince1970: 1_700_000_000) })

    let output = try await fetcher.fetch(.init(provider: .kiro, mode: .monitor))

    XCTAssertTrue(output.quotas.isEmpty)
    XCTAssertEqual(output.credentialAvailability, .present)
  }

  func testKiroMachineIdentifierPreservesOverrideAndHardwareFallback() {
    let defaults = UserDefaults(suiteName: #function)!
    defer { defaults.removePersistentDomain(forName: #function) }
    let credential = KiroQuotaCredential(accessToken: "token", accountKey: "person")
    let override = String(repeating: "a", count: 64)
    defaults.set(override, forKey: "KiroMachineId")

    XCTAssertEqual(
      KiroQuotaFetcher.machineIdentifier(
        for: credential,
        defaults: defaults,
        hardwareUUID: { "hardware" }
      ),
      override
    )

    defaults.set("invalid", forKey: "KiroMachineId")
    let expectedFallback = SHA256.hash(data: Data("hardware".utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    XCTAssertEqual(
      KiroQuotaFetcher.machineIdentifier(
        for: credential,
        defaults: defaults,
        hardwareUUID: { "hardware" }
      ),
      expectedFallback
    )
  }

  func testKiroRefreshesBeforeExpiryRetriesForbiddenOnceAndPersistsUnknownFileData() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let auth = home.appendingPathComponent(".aws/sso/cache/kiro-auth-token.json")
    try FileManager.default.createDirectory(
      at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"accessToken":"expired","refreshToken":"refresh","expiresAt":"2020-01-01T00:00:00Z","clientId":"client","clientSecret":"secret","region":"us-west-2","email":"person@example.com","unknown":"keep"}"#
        .utf8
    ).write(to: auth)
    let session = AdapterTestSession { request in
      if request.url?.host == "oidc.us-west-2.amazonaws.com" {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        XCTAssertEqual(body["grantType"], "refresh_token")
        return (#"{"accessToken":"rotated","refreshToken":"new-refresh","expiresIn":3600}"#, 200)
      }
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
      return (#"{"usageBreakdownList":[]}"#, 200)
    }
    let source = LocalKiroQuotaCredentialSource(homeDirectory: home.path)
    let fetcher = KiroQuotaFetcher(
      vault: AdapterTestVault(), metadata: AdapterTestMetadata(), credentials: source,
      session: session, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    let output = try await fetcher.fetch(.init(provider: .kiro, mode: .monitor))
    XCTAssertNotNil(output.quotas["person@example.com"])
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as! [String: Any]
    XCTAssertEqual(saved["unknown"] as? String, "keep")
    XCTAssertEqual(saved["accessToken"] as? String, "rotated")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o600)
  }

  func testKiroVaultCredentialsAreVisibleOnlyInMonitorMode() async throws {
    let account = Account.make(
      providerID: .init(rawValue: QuotaProvider.kiro.rawValue), accountKey: "vault-user",
      source: .quotioKeychain)
    let credential = StoredCredential(
      accessToken: "vault-token", refreshToken: nil, idToken: nil, accountID: nil,
      expiresAt: Date(timeIntervalSince1970: 2_000_000_000), extra: ["region": "us-east-1"])
    let fetcher = KiroQuotaFetcher(
      vault: AdapterTestVault(accounts: [account], credentials: [account.id: credential]),
      metadata: AdapterTestMetadata(), credentials: KiroTestSource([]),
      session: AdapterTestSession { _ in (#"{"usageBreakdownList":[]}"#, 200) },
      now: { Date(timeIntervalSince1970: 1_700_000_000) })

    let local = try await fetcher.fetch(.init(provider: .kiro, mode: .localProxy))
    let monitor = try await fetcher.fetch(.init(provider: .kiro, mode: .monitor))

    XCTAssertTrue(local.quotas.isEmpty)
    XCTAssertEqual(local.credentialAvailability, .missing)
    XCTAssertNotNil(monitor.quotas["vault-user"])
  }

  func testKiroAuthenticationHelpersPreserveIdentityAndRefreshBehavior() async throws {
    let expiring = KiroQuotaCredential(
      accessToken: "old", refreshToken: "refresh",
      expiresAt: Date(timeIntervalSince1970: 1_700_000_100), clientID: "client",
      clientSecret: "secret", region: "us-east-1", accountKey: "person")
    let source = KiroTestSource([expiring])
    let session = AdapterTestSession { request in
      if request.url?.host == "oidc.us-east-1.amazonaws.com" {
        return (#"{"accessToken":"new","expiresIn":3600}"#, 200)
      }
      return (#"{"userInfo":{"email":"person@example.com","userId":"person-id"}}"#, 200)
    }
    let fetcher = KiroQuotaFetcher(
      vault: AdapterTestVault(), metadata: AdapterTestMetadata(), credentials: source,
      session: session, now: { Date(timeIntervalSince1970: 1_700_000_000) })

    let refreshedCount = await fetcher.refreshAllLocalTokensIfNeeded()
    XCTAssertEqual(refreshedCount, 1)
    let identity = await fetcher.authenticatedAccountIdentity(
      accessToken: "new", expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
      clientID: "client", clientSecret: "secret", region: "us-east-1")
    XCTAssertEqual(identity, "person@example.com")
  }
}

private struct CopilotTestSource: CopilotQuotaCredentialSourcing {
  let values: [CopilotQuotaCredential]
  init(_ values: [CopilotQuotaCredential]) { self.values = values }
  func credentials() -> [CopilotQuotaCredential] { values }
}

private actor KiroTestSource: KiroQuotaCredentialSourcing {
  let values: [KiroQuotaCredential]
  init(_ values: [KiroQuotaCredential]) { self.values = values }
  func credentials() -> [KiroQuotaCredential] { values }
  func reload(path: String) -> KiroQuotaCredential? { values.first }
  func persist(
    path: String, expectedRefreshToken: String, accessToken: String, refreshToken: String?,
    expiresAt: Date
  ) {}
}

private actor AdapterTestSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  let handler: Handler
  init(_ handler: @escaping Handler) { self.handler = handler }
  func data(for request: URLRequest) -> (Data, URLResponse) {
    let result = handler(request)
    return (
      Data(result.0.utf8),
      HTTPURLResponse(url: request.url!, statusCode: result.1, httpVersion: nil, headerFields: nil)!
    )
  }
}

private actor AdapterTestVault: CredentialVault {
  let storedAccounts: [Account]
  let credentials: [String: StoredCredential]

  init(accounts: [Account] = [], credentials: [String: StoredCredential] = [:]) {
    storedAccounts = accounts
    self.credentials = credentials
  }

  func accounts() -> [Account] { storedAccounts }
  func credential(for accountID: String) -> StoredCredential? { credentials[accountID] }
  func reloadLatest(accountID: String) -> StoredCredential? { credentials[accountID] }
  func save(_ credential: StoredCredential, metadata: Account) throws {}
  func delete(accountID: String) {}
}

private actor AdapterTestMetadata: AccountMetadataRepository {
  func accounts() -> [Account] { [] }
  func disabledAccountIDs() -> Set<String> { [] }
  func saveAccount(_ account: Account) throws {}
  func deleteAccount(_ accountID: String) throws {}
  func setDisabled(_ disabled: Bool, accountID: String) throws {}
}
