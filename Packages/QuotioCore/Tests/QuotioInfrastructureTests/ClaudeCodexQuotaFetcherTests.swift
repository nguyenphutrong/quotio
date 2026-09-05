import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class ClaudeCodexQuotaFetcherTests: XCTestCase {
  func testClaudeMapsStableMetricsAndUsesSameRequestInBothModes() async throws {
    let body =
      #"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":70,"resets_at":null},"extra_usage":{"is_enabled":true,"monthly_limit":200,"used_credits":50,"utilization":25}}"#
    let session = RecordingQuotaSession(body: body)
    let loader = ClaudeLoader([.init(accountKey: "user@example.com", accessToken: "token")])
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(.init(provider: .claude, mode: mode, force: true))
      let quota = try XCTUnwrap(output.quotas["user@example.com"])
      XCTAssertEqual(
        quota.models.map(\.name), ["five-hour-session", "seven-day-weekly", "extra-usage"])
      XCTAssertEqual(quota.models.map(\.percentage), [75, 30, 75])
      XCTAssertEqual(
        quota.models.last?.presentation, .progress(used: 50, limit: 200, unit: .credits))
    }

    let requests = await session.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20" })
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.69" })
  }

  func testClaudeRetriesAuthenticationOnceAndThenEmitsForbidden() async throws {
    let session = RecordingQuotaSession(responses: [
      ("", 401),
      (#"{"access_token":"new-token"}"#, 200),
      ("", 403),
    ])
    let loader = ClaudeLoader([
      .init(accountKey: "Claude Code", accessToken: "old", refreshToken: "refresh")
    ])
    let output = try await ClaudeQuotaFetcher(credentials: loader, session: session)
      .fetch(.init(provider: .claude, mode: .monitor))
    XCTAssertEqual(output.quotas["Claude Code"]?.isForbidden, true)
    let requests = await session.requests()
    XCTAssertEqual(
      requests.map { $0.url?.absoluteString },
      [
        ClaudeQuotaFetcher.usageURL.absoluteString, ClaudeQuotaFetcher.tokenURL.absoluteString,
        ClaudeQuotaFetcher.usageURL.absoluteString,
      ])
    let refreshJSON =
      try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String]
    XCTAssertEqual(refreshJSON?["scope"], ClaudeQuotaFetcher.refreshScope)
  }

  func testClaudePersistsRotatedRefreshBeforeRetryingUsage() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let session = RecordingQuotaSession(responses: [
      ("", 401),
      (#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#, 200),
      (#"{"five_hour":{"utilization":25}}"#, 200),
    ])
    let loader = RecordingClaudeLoader([
      .init(accountKey: "Claude Code", accessToken: "old-access", refreshToken: "old-refresh")
    ])

    let output = try await ClaudeQuotaFetcher(credentials: loader, session: session, now: { now })
      .fetch(.init(provider: .claude, mode: .localProxy))

    XCTAssertEqual(output.quotas["Claude Code"]?.models.first?.percentage, 75)
    let persisted = await loader.persistedRefresh()
    XCTAssertEqual(persisted?.refresh.accessToken, "new-access")
    XCTAssertEqual(persisted?.refresh.refreshToken, "new-refresh")
    XCTAssertEqual(persisted?.refresh.expiresAt, now.addingTimeInterval(3_600))
    XCTAssertEqual(persisted?.expectedRefreshToken, "old-refresh")
  }

  func testCodexMapsWindowKindsSparkPlanAndHeadersInBothModes() async throws {
    let body =
      #"{"plan_type":"plus","rate_limit":{"limit_reached":false,"primary_window":{"used_percent":40,"limit_window_seconds":18000},"secondary_window":{"used_percent":12,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"GPT Spark","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000},"secondary_window":{"used_percent":30,"limit_window_seconds":604800}}}]}"#
    let session = RecordingQuotaSession(body: body)
    let loader = CodexLoader([
      .init(accountKey: "same@example.com-plus", accessToken: "token", accountID: "account-1")
    ])
    let fetcher = CodexQuotaFetcher(credentials: loader, session: session)

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .codex, scope: .account("same@example.com-plus"), mode: mode))
      let quota = try XCTUnwrap(output.quotas["same@example.com-plus"])
      XCTAssertEqual(
        quota.models.map(\.name),
        ["codex-session", "codex-weekly", "codex-spark", "codex-spark-weekly"])
      XCTAssertEqual(quota.planType, "plus")
    }
    let requests = await session.requests()
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1" })
  }

  func testCodexMergesUsageResetCreditAndProfileAnalytics() async throws {
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-01-01T12:00:00Z"))
    let usage = #"{"rate_limit":{"primary_window":{"used_percent":25}},"credits":{"balance":"125.9"},"rate_limit_reset_credits":{"available_count":9}}"#
    let resetCredits = #"{"available_count":2,"credits":[{"id":"future","status":"available","expires_at":"2030-01-02T00:00:00.500Z"},{"id":"expired","status":"available","expires_at":"2029-12-31T00:00:00Z"}]}"#
    let profile = #"{"stats":{"lifetime_tokens":4200000,"peak_daily_tokens":12000,"current_streak_days":3,"longest_streak_days":8,"longest_running_turn_sec":3725,"daily_usage_buckets":[{"date":"2029-12-31","tokens":1000},{"date":"2030-01-01","input_tokens":2000,"output_tokens":500}]}}"#
    let session = RecordingQuotaSession(responses: [
      (usage, 200),
      (resetCredits, 200),
      (profile, 200),
    ])
    let fetcher = CodexQuotaFetcher(
      credentials: CodexLoader([
        .init(accountKey: "Codex", accessToken: "token", accountID: "account-1")
      ]),
      session: session,
      now: { now }
    )

    let output = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))

    let quota = try XCTUnwrap(output.quotas["Codex"])
    let analytics = try XCTUnwrap(quota.analytics)
    XCTAssertEqual(
      analytics.rows.prefix(2).map(\.id),
      ["codex-extra-usage", "codex-rate-limit-resets"])
    XCTAssertEqual(analytics.rows[0].value, "$5.00 - 125 credits")
    XCTAssertEqual(analytics.rows[1].value, "2 available")
    XCTAssertEqual(
      analytics.rows.filter { $0.id.hasPrefix("codex-rate-limit-reset-") }.count,
      1)
    XCTAssertEqual(
      analytics.rows.first { $0.id == "codex-lifetime-tokens" }?.value,
      "4.2M tokens")
    XCTAssertEqual(
      analytics.rows.first { $0.id == "codex-longest-task" }?.value,
      "1h 2m")
    XCTAssertEqual(analytics.trend.map(\.date), ["2029-12-31", "2030-01-01"])
    XCTAssertEqual(analytics.trend.map(\.value), [1_000, 2_500])

    let requests = await session.requests()
    XCTAssertEqual(
      requests.map { $0.url?.absoluteString },
      [
        CodexQuotaFetcher.usageURL.absoluteString,
        CodexResetCreditInventoryFetcher.inventoryURL.absoluteString,
        CodexProfileAnalyticsFetcher.profileURL.absoluteString,
      ])
    XCTAssertTrue(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer token"
          && $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1"
      })
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "OpenAI-Beta"), "codex-1")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "originator"), "Codex Desktop")
    XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Originator"), "Codex Desktop")
  }

  func testCodexKeepsQuotaWhenOptionalAnalyticsRequestsFail() async throws {
    let usage = #"{"rate_limit":{"primary_window":{"used_percent":25}}}"#
    let session = RecordingQuotaSession(responses: [
      (usage, 200),
      ("not-json", 200),
      ("", 503),
    ])
    let fetcher = CodexQuotaFetcher(
      credentials: CodexLoader([.init(accountKey: "Codex", accessToken: "token")]),
      session: session
    )

    let output = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(output.quotas["Codex"]?.models.first?.percentage, 75)
    XCTAssertNil(output.quotas["Codex"]?.analytics)
  }

  func testCodexFreeWeeklyWindowAndCanonicalAliasesMatchLegacyBehavior() throws {
    let quota = try CodexQuotaFetcher.mapUsage(
      Data(
        #"{"rate_limit":{"primary_window":{"used_percent":"85","limit_window_seconds":604800}}}"#
          .utf8))
    XCTAssertEqual(quota.models.map(\.name), ["codex-weekly"])
    XCTAssertEqual(quota.models.first?.percentage, 15)

    let unique = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases([
      .init(accountKey: "same@example.com-plus", accessToken: "one", accountID: "account-1")
    ])
    XCTAssertEqual(unique, ["account-1": "same@example.com-plus"])
    let ambiguous = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases([
      .init(accountKey: "same@example.com-plus", accessToken: "one", accountID: "account-1"),
      .init(accountKey: "same@example.com-team", accessToken: "two", accountID: "account-1"),
    ])
    XCTAssertTrue(ambiguous.isEmpty)
  }

  func testCodexSessionOnlyWindowDoesNotFabricateWeeklyQuota() throws {
    let quota = try CodexQuotaFetcher.mapUsage(Data(#"""
      {
      "plan_type":"plus",
      "rate_limit":{
        "primary_window":{"used_percent":25,"limit_window_seconds":18000},
        "secondary_window":null
      }
      }
      """#.utf8))

    XCTAssertEqual(quota.models.map(\.name), ["codex-session"])
    XCTAssertEqual(quota.models.first?.usedPercentage, 25)
  }

  func testCodexMissingWindowSecondsUsesResetHorizon() throws {
    let quota = try CodexQuotaFetcher.mapUsage(Data(#"""
      {
      "plan_type":"free",
      "rate_limit":{
        "primary_window":{"used_percent":85,"reset_after_seconds":301573},
        "secondary_window":null
      }
      }
      """#.utf8))

    XCTAssertEqual(quota.models.map(\.name), ["codex-weekly"])
  }

  func testCodexMissingDurationSignalsUsePositionalFallback() throws {
    let quota = try CodexQuotaFetcher.mapUsage(Data(#"""
      {
      "plan_type":"plus",
      "rate_limit":{
        "primary_window":{"used_percent":40,"reset_after_seconds":3600},
        "secondary_window":{"used_percent":12}
      }
      }
      """#.utf8))

    XCTAssertEqual(quota.models.map(\.name), ["codex-session", "codex-weekly"])
  }

  func testCodexDeduplicatesWindowsClassifiedAsTheSameKind() throws {
    let quota = try CodexQuotaFetcher.mapUsage(Data(#"""
      {
      "plan_type":"free",
      "rate_limit":{
        "primary_window":{"used_percent":85,"limit_window_seconds":604800},
        "secondary_window":{"used_percent":20,"limit_window_seconds":604800}
      }
      }
      """#.utf8))

    XCTAssertEqual(quota.models.map(\.name), ["codex-weekly"])
    XCTAssertEqual(quota.models.first?.usedPercentage, 85)
  }

  func testCodexSkipsMalformedAdditionalLimitWithoutDiscardingPrimaryQuota() throws {
    let quota = try CodexQuotaFetcher.mapUsage(Data(#"""
      {
      "plan_type":"plus",
      "rate_limit":{
        "primary_window":{"used_percent":25,"limit_window_seconds":18000},
        "secondary_window":{"used_percent":10,"limit_window_seconds":604800}
      },
      "additional_rate_limits":[
        {"limit_name":"Broken","rate_limit":{"primary_window":{"used_percent":"invalid"}}},
        {"limit_name":"GPT Spark","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}
      ]
      }
      """#.utf8))

    XCTAssertEqual(
      quota.models.map(\.name),
      ["codex-session", "codex-weekly", "codex-spark"])
    XCTAssertEqual(quota.models.map(\.usedPercentage), [25, 10, 20])
  }

  func testCodexPublishesOnlySafeLegacyAliases() async throws {
    let session = RecordingQuotaSession(
      body: #"{"rate_limit":{"primary_window":{"used_percent":10}}}"#)
    let fetcher = CodexQuotaFetcher(
      credentials: CodexLoader([
        .init(
          accountKey: "same@example.com-plus",
          aliases: ["same@example.com"],
          accessToken: "token",
          accountID: "account-1"
        )
      ]),
      session: session
    )

    let output = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(output.quotas.keys.sorted(), ["same@example.com-plus"])
    XCTAssertEqual(output.accountAliases, ["same@example.com": "same@example.com-plus"])
  }

  func testCodexLegacyAliasRequiresOneKeyForAConcreteAccountID() {
    let missingIdentity = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases([
      .init(accountKey: "same@example.com-plus", accessToken: "one")
    ])
    let duplicateSources = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases([
      .init(accountKey: "same@example.com-plus", accessToken: "one", accountID: "account-1"),
      .init(accountKey: "same@example.com-plus", accessToken: "two", accountID: "account-1"),
    ])
    let distinctAccounts = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases([
      .init(accountKey: "same@example.com-plus", accessToken: "one", accountID: "account-1"),
      .init(accountKey: "same@example.com-team", accessToken: "two", accountID: "account-2"),
    ])

    XCTAssertTrue(missingIdentity.isEmpty)
    XCTAssertEqual(duplicateSources, ["account-1": "same@example.com-plus"])
    XCTAssertEqual(distinctAccounts, [
      "account-1": "same@example.com-plus",
      "account-2": "same@example.com-team",
    ])
  }

  func testCodexMonitorCredentialsPreferNativeSourceWithoutChangingLegacyAccountKey() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let legacyDirectory = directory.appendingPathComponent("legacy")
    let nativeURL = directory.appendingPathComponent("auth.json")
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(
      #"{"access_token":"legacy-token","account_id":"account-1"}"#.utf8
    ).write(to: legacyDirectory.appendingPathComponent("codex-same@example.com-plus.json"))
    let claims = try JSONSerialization.data(withJSONObject: ["email": "same@example.com"])
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    try JSONSerialization.data(withJSONObject: [
      "tokens": [
        "access_token": "native-token",
        "account_id": "account-1",
        "id_token": "header.\(claims).signature",
      ]
    ]).write(to: nativeURL)
    let loader = LocalCodexQuotaCredentialLoader(
      legacyDirectory: legacyDirectory.path,
      nativePaths: [nativeURL.path]
    )

    let localProxy = await loader.credentials(for: .localProxy)
    let monitor = await loader.credentials(for: .monitor)

    XCTAssertEqual(localProxy.map(\.accessToken), ["legacy-token"])
    XCTAssertEqual(monitor.map(\.accessToken), ["native-token"])
    XCTAssertEqual(monitor.map(\.accountKey), ["same@example.com-plus"])
    XCTAssertEqual(monitor.first?.aliases, ["same@example.com"])
  }

  func testCodexMonitorMergesVaultAndLegacyIdentityAndExportsCacheAlias() async throws {
    let account = Account.make(
      providerID: AccountProviderID(rawValue: "codex"),
      accountKey: "same@example.com",
      source: .nativeCredential
    )
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexLoader([
        .init(accountKey: "same@example.com-pro", accessToken: "legacy", accountID: "shared-id")
      ]),
      vault: CodexVault(account: account, credential: StoredCredential(
        accessToken: "vault", refreshToken: nil, idToken: nil,
        accountID: "shared-id", expiresAt: nil, extra: [:]
      )),
      metadata: CodexMetadata(),
      external: CodexExternalCredentials(record: nil)
    )

    let credentials = await loader.credentials(for: .monitor)
    XCTAssertEqual(credentials.map(\.accountKey), ["same@example.com"])
    XCTAssertEqual(credentials.map(\.accessToken), ["vault"])
    XCTAssertEqual(credentials.first?.aliases, ["same@example.com-pro"])

    let output = try await CodexQuotaFetcher(
      credentials: loader,
      session: RecordingQuotaSession(body: #"{"rate_limit":{"primary_window":{"used_percent":10}}}"#)
    ).fetch(.init(provider: .codex, mode: .monitor))
    XCTAssertEqual(output.credentialAccountKeys, ["same@example.com"])
    XCTAssertEqual(output.accountAliases, ["same@example.com-pro": "same@example.com"])
    XCTAssertEqual(Set(output.quotas.keys), ["same@example.com"])
  }

  func testCodexMonitorPreservesAliasesWhileProxyRetainsSeparateSourceKeys() async {
    let values: [CodexQuotaCredential] = [
      .init(accountKey: "same@example.com", aliases: ["native-alias"],
        accessToken: "native", accountID: "shared-id"),
      .init(accountKey: "same@example.com-pro", aliases: ["older-alias"],
        accessToken: "legacy", accountID: "shared-id"),
    ]
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexLoader(values), vault: CodexVault(), metadata: CodexMetadata(),
      external: CodexExternalCredentials(record: nil)
    )
    let monitor = await loader.credentials(for: .monitor)
    let proxy = await loader.credentials(for: .localProxy)
    XCTAssertEqual(monitor.count, 1)
    XCTAssertEqual(monitor.first?.aliases,
      ["native-alias", "older-alias", "same@example.com-pro"])
    XCTAssertEqual(proxy, values)
  }

  func testCodexIdentityMergePreservesDistinctAndUnknownAccountsAndProxyKeys() async {
    let values: [CodexQuotaCredential] = [
      .init(accountKey: "same@example.com-pro", accessToken: "a", accountID: "personal"),
      .init(accountKey: "same@example.com-team", accessToken: "b", accountID: "workspace"),
      .init(accountKey: "unknown-a", accessToken: "c"),
      .init(accountKey: "unknown-b", accessToken: "d"),
    ]
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexLoader(values), vault: CodexVault(), metadata: CodexMetadata(),
      external: CodexExternalCredentials(record: nil)
    )
    let monitor = await loader.credentials(for: .monitor)
    let proxy = await loader.credentials(for: .localProxy)
    XCTAssertEqual(monitor, values)
    XCTAssertEqual(proxy, values)
  }

  func testCodexRefreshExcludesNativeKeychainAccountAfterItIsDisabled() async throws {
    let accountKey = "person@example.com"
    let account = Account.make(
      providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
      accountKey: accountKey,
      source: .nativeCredential
    )
    let claims = try JSONSerialization.data(withJSONObject: ["email": accountKey])
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let credential = try JSONSerialization.data(withJSONObject: [
      "tokens": [
        "access_token": "native-token",
        "id_token": "header.\(claims).signature",
      ]
    ])
    let metadata = CodexMetadata()
    let loader = CompositeCodexQuotaCredentialLoader(
      local: CodexLoader([]),
      vault: CodexVault(),
      metadata: metadata,
      external: CodexExternalCredentials(record: ExternalCredentialRecord(
        data: credential,
        account: "Codex Auth"
      ))
    )
    let session = RecordingQuotaSession(
      body: #"{"rate_limit":{"primary_window":{"used_percent":10}}}"#)
    let fetcher = CodexQuotaFetcher(credentials: loader, session: session)

    let initial = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))
    try await metadata.setDisabled(true, accountID: account.id)
    let refreshed = try await fetcher.fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertNotNil(initial.quotas[accountKey])
    XCTAssertTrue(refreshed.quotas.isEmpty)
    XCTAssertEqual(refreshed.credentialAvailability, .missing)
    let requests = await session.requests()
    XCTAssertEqual(requests.count, 3)
  }

  func testCodexPersistsAllRotatedTokensBeforeRetryingUsage() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let usage =
      #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":10}}}"#
    let session = RecordingQuotaSession(responses: [
      ("", 401),
      (
        #"{"access_token":"new-access","refresh_token":"new-refresh","id_token":"new-id","expires_in":7200}"#,
        200
      ),
      (usage, 200),
    ])
    let loader = RecordingCodexLoader([
      .init(
        accountKey: "Codex", accessToken: "old-access", refreshToken: "old-refresh",
        idToken: "old-id")
    ])

    let output = try await CodexQuotaFetcher(credentials: loader, session: session, now: { now })
      .fetch(.init(provider: .codex, mode: .monitor))

    XCTAssertEqual(output.quotas["Codex"]?.models.first?.percentage, 90)
    let persisted = await loader.persistedRefresh()
    XCTAssertEqual(persisted?.refresh.accessToken, "new-access")
    XCTAssertEqual(persisted?.refresh.refreshToken, "new-refresh")
    XCTAssertEqual(persisted?.refresh.idToken, "new-id")
    XCTAssertEqual(persisted?.refresh.expiresAt, now.addingTimeInterval(7_200))
    XCTAssertEqual(persisted?.expectedRefreshToken, "old-refresh")
  }

  func testRefreshPersistencePreservesUnknownFieldsAndRejectsRotatedSource() throws {
    let refresh = QuotaTokenRefresh(
      accessToken: "new-access",
      refreshToken: "new-refresh",
      idToken: "new-id",
      expiresAt: Date(timeIntervalSince1970: 3_000)
    )
    let claude = Data(
      #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"expected","custom":"kept"},"root":"kept"}"#
        .utf8)
    let claudeUpdated = try XCTUnwrap(
      LocalClaudeQuotaCredentialLoader.updatedData(
        claude,
        refresh: refresh,
        replacing: "expected"
      ))
    let claudeJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: claudeUpdated) as? [String: Any])
    let claudeOAuth = try XCTUnwrap(claudeJSON["claudeAiOauth"] as? [String: Any])
    XCTAssertEqual(claudeJSON["root"] as? String, "kept")
    XCTAssertEqual(claudeOAuth["custom"] as? String, "kept")
    XCTAssertEqual(claudeOAuth["refreshToken"] as? String, "new-refresh")
    XCTAssertNil(
      LocalClaudeQuotaCredentialLoader.updatedData(
        claude,
        refresh: refresh,
        replacing: "already-rotated"
      ))

    let codex = Data(
      #"{"tokens":{"access_token":"old","refresh_token":"expected","custom":"kept"},"root":"kept"}"#
        .utf8)
    let codexUpdated = try XCTUnwrap(
      LocalCodexQuotaCredentialLoader.updatedData(
        codex,
        isNative: true,
        refresh: refresh,
        replacing: "expected"
      ))
    let codexJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: codexUpdated) as? [String: Any])
    let codexTokens = try XCTUnwrap(codexJSON["tokens"] as? [String: Any])
    XCTAssertEqual(codexJSON["root"] as? String, "kept")
    XCTAssertEqual(codexTokens["custom"] as? String, "kept")
    XCTAssertEqual(codexTokens["id_token"] as? String, "new-id")
    XCTAssertNil(
      LocalCodexQuotaCredentialLoader.updatedData(
        codex,
        isNative: true,
        refresh: refresh,
        replacing: "already-rotated"
      ))
  }
}

private struct ClaudeLoader: ClaudeQuotaCredentialLoading {
  let values: [ClaudeQuotaCredential]
  init(_ values: [ClaudeQuotaCredential]) { self.values = values }
  func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] { values }
}

private struct CodexLoader: CodexQuotaCredentialLoading {
  let values: [CodexQuotaCredential]
  init(_ values: [CodexQuotaCredential]) { self.values = values }
  func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential] { values }
}

private actor CodexVault: CredentialVault {
  private let account: Account?
  private let stored: StoredCredential?

  init(account: Account? = nil, credential: StoredCredential? = nil) {
    self.account = account
    stored = credential
  }

  func accounts() -> [Account] { account.map { [$0] } ?? [] }
  func credential(for accountID: String) -> StoredCredential? {
    account?.id == accountID ? stored : nil
  }
  func reloadLatest(accountID: String) -> StoredCredential? { nil }
  func save(_ credential: StoredCredential, metadata: Account) throws {}
  func delete(accountID: String) {}
}

private actor CodexMetadata: AccountMetadataRepository {
  private var disabledIDs = Set<String>()

  func accounts() -> [Account] { [] }
  func disabledAccountIDs() -> Set<String> { disabledIDs }
  func saveAccount(_ account: Account) throws {}
  func deleteAccount(_ accountID: String) throws {}

  func setDisabled(_ disabled: Bool, accountID: String) throws {
    if disabled {
      disabledIDs.insert(accountID)
    } else {
      disabledIDs.remove(accountID)
    }
  }
}

private actor CodexExternalCredentials: ExternalCredentialReading {
  private let record: ExternalCredentialRecord?

  init(record: ExternalCredentialRecord?) {
    self.record = record
  }

  func read(service: String, account: String?) -> ExternalCredentialRecord? { record }

  func compareAndSwap(
    service: String,
    account: String,
    expectedData: Data,
    newData: Data
  ) -> Bool { false }
}

private actor RecordingClaudeLoader: ClaudeQuotaCredentialLoading {
  struct Persisted: Sendable {
    let refresh: QuotaTokenRefresh
    let expectedRefreshToken: String
  }

  private var values: [ClaudeQuotaCredential]
  private var persisted: Persisted?

  init(_ values: [ClaudeQuotaCredential]) { self.values = values }

  func credentials(for mode: QuotaOperatingMode) -> [ClaudeQuotaCredential] { values }

  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) {
    persisted = Persisted(refresh: refresh, expectedRefreshToken: expectedRefreshToken)
    values = values.map {
      guard $0.accountKey == credential.accountKey else { return $0 }
      return ClaudeQuotaCredential(
        accountKey: $0.accountKey,
        accessToken: refresh.accessToken,
        refreshToken: refresh.refreshToken ?? $0.refreshToken,
        expiresAt: refresh.expiresAt ?? $0.expiresAt
      )
    }
  }

  func persistedRefresh() -> Persisted? { persisted }
}

private actor RecordingCodexLoader: CodexQuotaCredentialLoading {
  struct Persisted: Sendable {
    let refresh: QuotaTokenRefresh
    let expectedRefreshToken: String
  }

  private var values: [CodexQuotaCredential]
  private var persisted: Persisted?

  init(_ values: [CodexQuotaCredential]) { self.values = values }

  func credentials(for mode: QuotaOperatingMode) -> [CodexQuotaCredential] { values }

  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) {
    persisted = Persisted(refresh: refresh, expectedRefreshToken: expectedRefreshToken)
    values = values.map {
      guard $0.accountKey == credential.accountKey else { return $0 }
      return CodexQuotaCredential(
        accountKey: $0.accountKey,
        accessToken: refresh.accessToken,
        refreshToken: refresh.refreshToken ?? $0.refreshToken,
        idToken: refresh.idToken ?? $0.idToken,
        accountID: $0.accountID
      )
    }
  }

  func persistedRefresh() -> Persisted? { persisted }
}

private actor RecordingQuotaSession: QuotaHTTPSession {
  private var queued: [(String, Int)]
  private var recorded: [URLRequest] = []

  init(body: String) { queued = Array(repeating: (body, 200), count: 8) }
  init(responses: [(String, Int)]) { queued = responses }

  func data(for request: URLRequest) throws -> (Data, URLResponse) {
    recorded.append(request)
    let response = queued.isEmpty ? ("", 404) : queued.removeFirst()
    return (
      Data(response.0.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: nil)!
    )
  }

  func requests() -> [URLRequest] { recorded }
}
