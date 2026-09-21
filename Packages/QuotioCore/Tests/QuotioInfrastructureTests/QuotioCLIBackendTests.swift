import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class QuotioCLIBackendTests: XCTestCase {
    override func tearDown() {
        QuotioCLIURLProtocol.reset()
        super.tearDown()
    }

    func testUsageReportMapsCanonicalProviderAndRemainingPercentage() throws {
        let data = Data(#"""
        {
          "schema_version": 1,
          "generated_at": "2026-09-16T12:00:00Z",
          "providers": [{
            "provider": "factory",
            "account_ref": {"origin":"owned","id":"account-1","label":"Work"},
            "account": {"id":"user-1","label":"Work","plan":"pro"},
            "windows": [{
              "label":"Weekly","metric_id":"weekly","quota":{"state":"available","used_percent":25,"remaining_percent":75},
              "resets_at":null,"provenance":{"source":"test","confidence":"exact"},
              "fetched_at":"2026-09-16T12:00:00Z"
            }]
          }],
          "failures": []
        }
        """#.utf8)

        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
        let snapshot = QuotioCLIUsageMapper.snapshot(report)

        XCTAssertEqual(snapshot.quotas[.factoryDroid]?["Work"]?.models.first?.percentage, 75)
        XCTAssertEqual(snapshot.accountAliases[.factoryDroid]?["account-1"], "Work")
        XCTAssertEqual(snapshot.accountIDs[.factoryDroid]?["Work"], "account-1")
    }

    func testUsageReportUsesReferenceLabelsAndKeepsCollidingProviderLabelsDistinct() throws {
        let data = Data(#"""
        {
          "schema_version":1,"generated_at":"2026-09-16T12:00:00Z","failures":[],
          "providers":[
            {"provider":"openrouter","account_ref":{"origin":"owned","id":"account-1","label":"Work"},"account":{"id":"api-key","label":"API Key","plan":null},"windows":[]},
            {"provider":"openrouter","account_ref":{"origin":"owned","id":"account-2","label":"Personal"},"account":{"id":"api-key","label":"API Key","plan":null},"windows":[]}
          ]
        }
        """#.utf8)

        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
        let snapshot = QuotioCLIUsageMapper.snapshot(report)

        XCTAssertEqual(Set(snapshot.quotas[.openRouter]?.keys.map(\.self) ?? []), ["Work", "Personal"])
        XCTAssertEqual(snapshot.quotas[.openRouter]?["Work"]?.accountDisplayName, "Work")
        XCTAssertEqual(snapshot.quotas[.openRouter]?["Personal"]?.accountDisplayName, "Personal")
        XCTAssertEqual(snapshot.accountIDs[.openRouter]?["Work"], "account-1")
        XCTAssertEqual(snapshot.accountIDs[.openRouter]?["Personal"], "account-2")
    }

    func testUsageReportMapsCodexAnalyticsAndResetCredits() throws {
        let data = Data(#"""
        {
          "schema_version":1,"generated_at":"2026-09-16T12:00:00Z","failures":[],
          "providers":[{
            "provider":"codex","account":{"id":"user-1","label":"Codex User","plan":"plus"},"windows":[],
            "codex_profile":{
              "daily_usage":[{"date":"2026-09-15","tokens":1200}],
              "latest_30_buckets_tokens":1200,"lifetime_tokens":8000,"peak_daily_tokens":1200,
              "longest_running_turn_seconds":3661,"current_streak_days":1,"longest_streak_days":3,
              "fetched_at":"2026-09-16T11:00:00Z"
            },
            "codex_reset_credits":{
              "available_count":2,
              "credits":[{"id":"hashed-credit","expires_at":"2026-09-18T12:00:00Z"}],
              "fetched_at":"2026-09-16T11:30:00Z"
            }
          }]
        }
        """#.utf8)

        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
        let quota = try XCTUnwrap(QuotioCLIUsageMapper.snapshot(report).quotas[.codex]?["Codex User"])

        XCTAssertEqual(quota.lastUpdated, ISO8601DateFormatter().date(from: "2026-09-16T11:00:00Z"))
        XCTAssertEqual(quota.analytics?.rows.first { $0.id == "codex-lifetime-tokens" }?.value, "8K tokens")
        XCTAssertEqual(quota.analytics?.rows.first { $0.id == "codex-rate-limit-resets" }?.value, "2 available")
        XCTAssertNotNil(quota.analytics?.rows.first { $0.id == "codex-rate-limit-reset-hashed-credit" })
    }

    func testAccountCreateUsesBearerAndIdempotencyHeaders() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        try await backend.saveAPIKey(
            providerID: AccountProviderID(rawValue: QuotaProvider.openRouter.rawValue),
            label: "Primary",
            apiKey: "secret",
            existingAccountID: nil
        )

        let request = try XCTUnwrap(QuotioCLIURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/accounts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testScopedRefreshUsesBorrowedAccountIDFromUsageSnapshot() async throws {
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"borrowed-1","label":"CLI User"},"account":{"id":"user-1","label":"CLI User","plan":null},"windows":[]}],"failures":[]}"#
        for accountKey in ["CLI User", "borrowed-1"] {
            QuotioCLIURLProtocol.reset()
            QuotioCLIURLProtocol.enqueue(report)
            QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
            QuotioCLIURLProtocol.enqueue(report)
            let backend = QuotioCLIBackend(session: stubSession())
            await backend.connect(QuotioCLIConnection(
                baseURL: URL(string: "http://127.0.0.1:43210")!,
                token: "private-token"
            ))

            _ = await backend.bootstrap(mode: .monitor)
            _ = await backend.refresh(QuotaFetchRequest(
                provider: .claude,
                scope: .account(accountKey),
                mode: .monitor,
                force: true
            ))

            let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/refresh"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["account_id"] as? String, "borrowed-1")
            XCTAssertEqual(json["include_owned"] as? Bool, true)
            XCTAssertFalse(QuotioCLIURLProtocol.requests().contains { $0.url?.path == "/v1/accounts" })
        }
    }

    func testLocalProxyModeExcludesOwnedUsageAndPreservesBorrowedAccountSource() async throws {
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Managed"},"account":{"id":"managed","label":"Managed","plan":null},"windows":[]},{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"borrowed-1","label":"CLI User"},"account":{"id":"user-1","label":"CLI User","plan":null},"windows":[]}],"failures":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Managed"},"code":"authentication"}]}"#
        QuotioCLIURLProtocol.enqueue(report)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"owned-1","provider":"claude","label":"Managed","origin":"owned","enabled":true,"source_kind":null}]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        let snapshot = await backend.bootstrap(mode: .localProxy)
        let accounts = await backend.accounts()

        XCTAssertNil(snapshot.quotas[.claude]?["Managed"])
        XCTAssertTrue(snapshot.accountIssues.isEmpty)
        XCTAssertNotNil(snapshot.quotas[.claude]?["CLI User"])
        XCTAssertEqual(accounts.map(\.source), [.legacyCLIProxy])
    }

    func testLocalProxyModeKeepsOwnedWarpUsage() throws {
        let data = Data(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"warp","account_ref":{"origin":"owned","id":"warp-1","label":"__quotio_local_warp__:Work"},"account":{"id":"warp","label":"Work","plan":null},"windows":[]}],"failures":[]}"#.utf8)
        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)

        let snapshot = QuotioCLIUsageMapper.snapshot(report, mode: .localProxy)

        XCTAssertNotNil(snapshot.quotas[.warp]?["Work"])
    }

    func testSynchronizeWarpTokensOnlyUpdatesAndRemovesMirroredAccounts() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"monitor","provider":"warp","label":"Monitor","origin":"owned","enabled":true,"source_kind":null},{"id":"warp-1","provider":"warp","label":"__quotio_local_warp__:Work","origin":"owned","enabled":true,"source_kind":null},{"id":"warp-2","provider":"warp","label":"__quotio_local_warp__:Old","origin":"owned","enabled":true,"source_kind":null}]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-2","status":"completed","error":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        try await backend.synchronizeWarpTokens([WarpToken(name: "Work", token: "new-token")])

        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PATCH", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/accounts", "/v1/accounts/warp-1", "/v1/accounts/warp-2"])
    }

    func testExpiredDeviceCodeUsesProviderDeadline() async throws {
        let expired = Int64(Date().timeIntervalSince1970) - 1
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"waiting","account_id":null,"error_code":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"waiting","account_id":null,"error_code":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"failed","account_id":null,"error_code":"unexpected_poll"}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))
        let authorizer = QuotioCLIOAuthAuthorizer(
            backend: backend,
            urlOpener: QuotioCLIURLOpenerStub(),
            callbackTransport: QuotioCLICallbackTransportStub()
        )

        do {
            _ = try await authorizer.begin(
                request: OAuthAuthorizationRequest(
                    providerID: AccountProviderID(rawValue: QuotaProvider.copilot.rawValue)
                ),
                attemptID: OAuthAttemptID(),
                progress: { _ in }
            )
            XCTFail("Expected the provider deadline to expire the session")
        } catch {
            XCTAssertEqual(error as? OAuthFlowFailure, .expired)
        }
        XCTAssertEqual(QuotioCLIURLProtocol.requests().count, 2)
    }

    func testOAuthCallbackUsesExchangeTimeout() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"provider":"codex","workflow":"browser_redirect","user_code":null,"id":"session-1","url":"https://example.com","expires_at":4102444800,"status":"completed","account_id":"account-1","error_code":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        _ = try await backend.completeOAuth(id: "session-1", code: "code")

        XCTAssertEqual(QuotioCLIURLProtocol.requests().first?.timeoutInterval, 60)
    }

    func testRefreshSynchronizesSavedCustomProviderReference() async throws {
        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let provider = CustomProvider(
            id: providerID,
            name: "Work Z.ai",
            type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "secret")]
        )
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"source-operation","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh-operation","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(
            session: stubSession(),
            customProviders: { [provider] },
            customProviderDomain: "com.example.quotio"
        )
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        _ = await backend.refresh(QuotaFetchRequest(
            provider: .glm,
            mode: .monitor,
            force: true
        ))

        let data = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/account-sources"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try XCTUnwrap(body["source"] as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "quotio_custom_provider")
        XCTAssertEqual(source["domain"] as? String, "com.example.quotio")
        XCTAssertEqual(source["record_id"] as? String, providerID.uuidString)
    }

    func testRefreshKeepsMatchingCustomProviderReference() async throws {
        let provider = CustomProvider(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Work Z.ai",
            type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "secret")]
        )
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"custom-1","provider":"zai","label":"Work Z.ai","origin":"borrowed_native","enabled":true,"source_kind":"quotio_custom_provider","source_id":"8c5323370293dc7d3ad3b61ed18ce2bb8191ebc3e743d93fdc5e5b6d8504c20e"}]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh-operation","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(
            session: stubSession(),
            customProviders: { [provider] },
            customProviderDomain: "com.example.quotio"
        )
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        _ = await backend.refresh(QuotaFetchRequest(provider: .glm, mode: .monitor, force: true))

        XCTAssertEqual(
            QuotioCLIURLProtocol.requests().compactMap { $0.url?.path },
            ["/v1/accounts", "/v1/refresh", "/v1/usage"]
        )
    }

    func testRefreshUpdatesRenamedCustomProviderReference() async throws {
        let provider = CustomProvider(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Renamed Z.ai", type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "secret")]
        )
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"custom-1","provider":"zai","label":"Work Z.ai","origin":"borrowed_native","enabled":true,"source_kind":"quotio_custom_provider","source_id":"8c5323370293dc7d3ad3b61ed18ce2bb8191ebc3e743d93fdc5e5b6d8504c20e"}]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"rename","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession(), customProviders: { [provider] }, customProviderDomain: "com.example.quotio")
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))

        _ = await backend.refresh(QuotaFetchRequest(provider: .glm, mode: .monitor))

        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PATCH", "POST", "GET"])
        let data = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/accounts/custom-1"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(body, ["label": "Renamed Z.ai"])
    }

    func testRemovedCursorQuotaStaysRemovedUntilExplicitImport() async throws {
        let suite = "QuotioCLIBackendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"cursor","account_ref":{"origin":"borrowed_native","id":"cursor-1","label":"Work"},"account":{"id":"cursor-user","label":"Work"},"windows":[]}],"failures":[]}"#
        let backend = QuotioCLIBackend(session: stubSession(), userDefaults: defaults)
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        QuotioCLIURLProtocol.enqueue(#"{"id":"import","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(report)
        let imported = await backend.refresh(QuotaFetchRequest(provider: .cursor, mode: .monitor))
        XCTAssertNotNil(imported.quotas[.cursor]?["Work"])
        await backend.removeQuota(for: QuotaAccountID(provider: .cursor, accountKey: "Work"), mode: .monitor)

        for request in [
            QuotaFetchRequest(provider: .claude, mode: .monitor),
            QuotaFetchRequest(provider: .cursor, scope: .importedAccounts(["Personal"]), mode: .monitor),
        ] {
            QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
            QuotioCLIURLProtocol.enqueue(report)
            let snapshot = await backend.refresh(request)
            XCTAssertNil(snapshot.quotas[.cursor]?["Work"])
            XCTAssertNil(snapshot.accountIDs[.cursor]?["Work"])
            XCTAssertNil(snapshot.accountAliases[.cursor]?["cursor-1"])
            XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "persisted.ideQuotas"))
        }
        QuotioCLIURLProtocol.enqueue(report)
        let restored = await backend.bootstrap(mode: .monitor)
        XCTAssertNil(restored.quotas[.cursor]?["Work"])
        QuotioCLIURLProtocol.enqueue(#"{"id":"reimport","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(report)
        let reimported = await backend.refresh(QuotaFetchRequest(provider: .cursor, mode: .monitor))
        XCTAssertNotNil(reimported.quotas[.cursor]?["Work"])
    }

    func testBootstrapRestoresImportedIDEQuotaSelection() async throws {
        let suite = "QuotioCLIBackendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "monthly", percentage: 42, resetTime: "")]
        )
        defaults.set(
            try JSONEncoder().encode([
                QuotaProvider.cursor.rawValue: ["person@example.com": quota],
                QuotaProvider.trae.rawValue: ["person@example.com": quota],
            ]),
            forKey: "persisted.ideQuotas"
        )
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession(), userDefaults: defaults)
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        let snapshot = await backend.bootstrap(mode: .monitor)

        XCTAssertEqual(snapshot.quotas[.cursor]?["person@example.com"], quota)
        XCTAssertNil(snapshot.quotas[.trae])

        for provider in [QuotaProvider.claude, .cursor] {
            QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed","error":null}"#)
            QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
            let refreshed = await backend.refresh(QuotaFetchRequest(provider: provider, mode: .monitor))
            if provider == .claude {
                XCTAssertEqual(refreshed.quotas[.cursor]?["person@example.com"], quota)
            } else {
                XCTAssertNil(refreshed.quotas[.cursor])
                XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "persisted.ideQuotas"))
            }
        }
    }

    func testFailedBorrowedAccountRemainsVisibleAndCanBeRefreshed() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"proxy-1","label":"Work"},"code":"authentication"}]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"
        ))

        let snapshot = await backend.bootstrap(mode: .monitor)
        let accounts = await backend.accounts()
        XCTAssertEqual(accounts.map(\.id), ["proxy-1"])
        XCTAssertEqual(accounts.map(\.accountKey), ["Work"])
        XCTAssertNotNil(snapshot.accountIssues[QuotaAccountID(provider: .claude, accountKey: "Work")])

        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        _ = await backend.refresh(QuotaFetchRequest(provider: .claude, scope: .account("Work"), mode: .monitor))
        let data = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/refresh"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["account_id"] as? String, "proxy-1")
    }

    func testLocalProxyRefreshExcludesOwnedSources() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        _ = await backend.refreshAll(mode: .localProxy, providers: [.claude], force: true)

        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/refresh"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["include_owned"] as? Bool, false)
    }

    func testModeSwitchClearsPreviousSnapshotWhenReloadFails() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Managed"},"account":{"id":"managed","label":"Managed","plan":null},"windows":[]}],"failures":[]}"#)
        QuotioCLIURLProtocol.enqueue("{}")
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        let monitorSnapshot = await backend.bootstrap(mode: .monitor)
        let localSnapshot = await backend.bootstrap(mode: .localProxy)

        XCTAssertNotNil(monitorSnapshot.quotas[.claude]?["Managed"])
        XCTAssertTrue(localSnapshot.quotas.isEmpty)
        XCTAssertNotNil(localSnapshot.issues[.claude])
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotioCLIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private struct QuotioCLIURLOpenerStub: URLOpening {
    func open(_ url: URL) -> Bool { true }
}

private actor QuotioCLICallbackTransportStub: OAuthCallbackTransport {
    func start(preferredPort: UInt16?) async throws -> UInt16 { preferredPort ?? 0 }
    func waitForCallback(timeout: Duration) async throws -> URL {
        throw OAuthFlowFailure.expired
    }
    func stop() async {}
}

private final class QuotioCLIURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var recordedBodies: [Data?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestBody = Self.readBody(from: request)
        let body = Self.lock.withLock { () -> Data in
            Self.recordedRequests.append(request)
            Self.recordedBodies.append(requestBody)
            return Self.bodies.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(_ body: String) {
        lock.withLock { bodies.append(Data(body.utf8)) }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func body(forPath path: String) -> Data? {
        lock.withLock {
            zip(recordedRequests, recordedBodies).first { $0.0.url?.path == path }?.1
        }
    }

    static func reset() {
        lock.withLock {
            bodies = []
            recordedRequests = []
            recordedBodies = []
        }
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(buffer, count: count)
        }
    }
}
