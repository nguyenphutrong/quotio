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

    func testRemovingQuotaOnlyRemovesAliasesForThatAccount() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"amp","account_ref":{"origin":"owned","id":"work-id","label":"Work"},"account":{"id":"work","label":"Work"},"windows":[]},{"provider":"amp","account_ref":{"origin":"owned","id":"personal-id","label":"Personal"},"account":{"id":"personal","label":"Personal"},"windows":[]}],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test-token"))
        _ = await backend.bootstrap(mode: .monitor)

        await backend.removeQuota(for: QuotaAccountID(provider: .amp, accountKey: "Work"), mode: .monitor)

        let snapshot = await backend.snapshot
        XCTAssertEqual(snapshot.accountAliases[.amp], ["personal-id": "Personal", "Personal": "Personal"])
        XCTAssertEqual(snapshot.accountIDs[.amp], ["Personal": "personal-id"])
        XCTAssertNil(snapshot.quotas[.amp]?["Work"])
        XCTAssertNotNil(snapshot.quotas[.amp]?["Personal"])
    }

    func testUsageReportMapsCodexAnalyticsAndResetCredits() throws {
        let data = Data(#"""
        {
          "schema_version":1,"generated_at":"2026-09-16T12:00:00Z","failures":[],
          "providers":[{
            "provider":"codex","account":{"id":"user-1","label":"Codex User","plan":"plus"},"windows":[
                {"label":"Unlimited","quota":{"state":"unlimited"},"fetched_at":"2026-09-16T12:00:00Z"},
                {"label":"Disabled","quota":{"state":"disabled"},"fetched_at":"2026-09-16T12:00:00Z"},
                {"label":"Limit","quota":{"state":"limit","amount":5,"unit":"USD"},"fetched_at":"2026-09-16T12:00:00Z"}
            ],
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

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let catalog = try Data(contentsOf: repository.appendingPathComponent("apps/macos/Quotio/Localizable.xcstrings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localizedDirectory = directory.appendingPathComponent("fr.lproj")
        try FileManager.default.createDirectory(at: localizedDirectory, withIntermediateDirectories: true)
        var translations: [String: String] = [:]
        for (key, entry) in strings {
            guard let locales = entry["localizations"] as? [String: [String: Any]] else { continue }
            if key.hasPrefix("quota.analytics.") || key == "quota.metric.unlimited" {
                XCTAssertEqual(Set(locales.keys), ["en", "fr", "vi", "zh-Hans"], key)
            }
            if let unit = locales["fr"]?["stringUnit"] as? [String: String] {
                translations[key] = unit["value"]
            }
        }
        let localizedData = try PropertyListSerialization.data(fromPropertyList: translations, format: .xml, options: 0)
        try localizedData.write(to: localizedDirectory.appendingPathComponent("Localizable.strings"))
        let bundle = try XCTUnwrap(Bundle(path: localizedDirectory.path))
        let localized = try XCTUnwrap(QuotioCLIUsageMapper.snapshot(report, bundle: bundle, locale: Locale(identifier: "fr")).quotas[.codex]?["Codex User"])
        XCTAssertEqual(localized.analytics?.rows.first { $0.id == "today" }?.title, "Aujourd’hui")
        XCTAssertEqual(localized.analytics?.rows.first { $0.id == "today" }?.value, "Aucune donnée")
        XCTAssertEqual(localized.analytics?.rows.first { $0.id == "codex-longest-task" }?.value, "1 h 1 min")
        XCTAssertEqual(localized.analytics?.rows.first { $0.id == "codex-current-streak" }?.value, "1 jour")
        XCTAssertEqual(localized.analytics?.rows.first { $0.id == "codex-rate-limit-resets" }?.value, "2 disponibles")
        XCTAssertTrue(localized.analytics?.rows.first { $0.id == "codex-rate-limit-reset-hashed-credit" }?.value.hasPrefix("dans ") == true)
        XCTAssertEqual(localized.models[0].presentation, .status(text: "Illimité"))
        XCTAssertEqual(localized.models[1].presentation, .status(text: "Désactivé"))
        XCTAssertEqual(localized.models[2].presentation, .status(text: "Plafond de 5 USD"))
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

    func testLegacyImportUsesStableReceiptAndUnixExpiry() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        let account = Account.make(providerID: AccountProviderID(rawValue: "kiro"), accountKey: "Work", source: .quotioKeychain)
        let credential = StoredCredential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil, accountID: "user", expiresAt: Date(timeIntervalSince1970: 1_700_000_000.9), extra: ["authMethod": "IdC", "clientId": "synthetic-client", "clientSecret": "synthetic-secret"])
        for _ in 0..<2 {
            QuotioCLIURLProtocol.enqueue(#"{"id":"import","status":"completed"}"#)
            try await backend.importLegacyAccount(account, credential: credential, disabled: true)
        }
        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/accounts/migrate"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(value["enabled"] as? Bool, false)
        XCTAssertEqual(value["provider"] as? String, "kiro")
        let imported = try XCTUnwrap(value["credential"] as? [String: Any])
        XCTAssertEqual(imported["expires_at"] as? Int64, 1_700_000_000)
        XCTAssertEqual((imported["extra"] as? [String: String])?["clientSecret"], "synthetic-secret")
    }

    func testLegacyImportRejectsOutOfRangeExpiryWithoutSendingCredential() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        let account = Account.make(providerID: AccountProviderID(rawValue: "claude"), accountKey: "Work", source: .quotioKeychain)
        let credential = StoredCredential(accessToken: "synthetic", refreshToken: "synthetic-refresh", idToken: nil, accountID: "user", expiresAt: Date(timeIntervalSince1970: 1e100), extra: [:])
        do {
            try await backend.importLegacyAccount(account, credential: credential, disabled: false)
            XCTFail("Invalid dates must be reported without trapping")
        } catch { }
        XCTAssertTrue(QuotioCLIURLProtocol.requests().isEmpty)
    }

    func testOriginlessUsageAccountsAreReadOnlyNativeCredentials() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"codex","account_ref":{"id":"local","label":"Local"},"account":{"id":"user","label":"Local"},"windows":[]}],"failures":[]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        _ = await backend.bootstrap(mode: .monitor)

        let accounts = await backend.accounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.source, .nativeCredential)
        XCTAssertEqual(accounts.first?.capabilities, [])
    }

    func testAccountsPreserveDisabledStateWhenMergingUsageReferences() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Work"},"account":{"id":"user","label":"Work"},"windows":[]}],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        _ = await backend.bootstrap(mode: .monitor)

        for enabled in [false, true] {
            QuotioCLIURLProtocol.enqueue("{\"schema_version\":1,\"accounts\":[{\"id\":\"owned-1\",\"provider\":\"claude\",\"label\":\"Work\",\"origin\":\"owned\",\"enabled\":\(enabled)}]}")
            let accounts = await backend.accounts()
            XCTAssertEqual(accounts.count, 1)
            XCTAssertEqual(accounts.first?.isDisabled, !enabled)
            XCTAssertTrue(accounts.first?.capabilities.contains(.disable) == true)
        }
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

    func testScopedSnapshotFailureOnlyMarksRefreshedProvider() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account":{"id":"claude-1","label":"Work"},"windows":[]},{"provider":"codex","account":{"id":"codex-1","label":"Personal"},"windows":[]}],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        let initial = await backend.bootstrap(mode: .monitor)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue("{}")

        let failed = await backend.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))

        XCTAssertEqual(Set(failed.issues.keys), [.claude])
        XCTAssertEqual(failed.issues[.claude]?.kind, .failed)
        XCTAssertEqual(failed.quotas, initial.quotas)
        XCTAssertTrue(failed.refreshingProviders.isEmpty)

        QuotioCLIURLProtocol.enqueue("{}")
        let bootstrapFailure = await backend.bootstrap(mode: .monitor)
        XCTAssertEqual(bootstrapFailure.issues[.codex]?.kind, .failed)
    }

    func testScopedRefreshAfterMutationPreservesUnaffectedProviderState() async throws {
        let report = #"""
        {"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[
            {"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"claude-1","label":"Work"},"account":{"id":"user","label":"Work"},"windows":[],"diagnostics":[{"code":"transient"}]},
            {"provider":"antigravity","account_ref":{"origin":"borrowed_proxy","id":"ag-1","label":"Personal"},"account":{"id":"user","label":"Personal"},"windows":[],"antigravity_subscription":{"current_tier":{"id":"pro","name":"Pro"}}}
        ],"failures":[
            {"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"claude-1","label":"Work"},"code":"transient"},
            {"provider":"amp","account_ref":{"origin":"borrowed_proxy","id":"amp-1","label":"Local"},"code":"authentication"},
            {"provider":"codex","code":"credential_storage"}
        ]}
        """#
        let emptyReport = #"{"schema_version":1,"generated_at":"2026-09-16T12:01:00Z","providers":[],"failures":[]}"#
        QuotioCLIURLProtocol.enqueue(report)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        let initial = await backend.bootstrap(mode: .monitor)

        QuotioCLIURLProtocol.enqueue(#"{"id":"mutation","status":"completed"}"#)
        try await backend.saveAPIKey(providerID: AccountProviderID(rawValue: "openrouter"), label: "New", apiKey: "test-key", existingAccountID: nil)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:01:00Z","providers":[{"provider":"openrouter","account_ref":{"origin":"owned","id":"new-1","label":"New"},"account":{"id":"user","label":"New"},"windows":[]}],"failures":[]}"#)
        let refreshed = await backend.refresh(QuotaFetchRequest(provider: .openRouter, mode: .monitor))

        for provider in [QuotaProvider.claude, .antigravity, .amp, .codex] {
            XCTAssertEqual(refreshed.quotas[provider], initial.quotas[provider])
            XCTAssertEqual(refreshed.accountAliases[provider], initial.accountAliases[provider])
            XCTAssertEqual(refreshed.accountIDs[provider], initial.accountIDs[provider])
            XCTAssertEqual(refreshed.subscriptions[provider], initial.subscriptions[provider])
            XCTAssertEqual(refreshed.issues[provider], initial.issues[provider])
        }
        XCTAssertEqual(refreshed.accountIssues, initial.accountIssues)
        XCTAssertNotNil(refreshed.quotas[.openRouter]?["New"])
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[]}"#)
        let accounts = await backend.accounts()
        XCTAssertEqual(Set(accounts.map(\.id)), ["claude-1", "ag-1", "amp-1", "new-1"])

        // An empty refreshed scope must still remove its old results and issues.
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(emptyReport)
        let removed = await backend.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        XCTAssertNil(removed.quotas[.claude])
        XCTAssertNil(removed.accountIDs[.claude])
        XCTAssertNil(removed.accountIssues[QuotaAccountID(provider: .claude, accountKey: "Work")])
        XCTAssertEqual(removed.quotas[.antigravity], initial.quotas[.antigravity])
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[]}"#)
        let remainingAccounts = await backend.accounts()
        XCTAssertEqual(Set(remainingAccounts.map(\.id)), ["ag-1", "amp-1", "new-1"])

        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh-all","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(emptyReport)
        let all = await backend.refreshAll(mode: .monitor)
        XCTAssertTrue(all.quotas.values.allSatisfy(\.isEmpty))
        XCTAssertTrue(all.accountIssues.isEmpty)
        XCTAssertTrue(all.issues.isEmpty)
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

    func testLocalProxyModeOnlyKeepsWarpMirrorsIncludingCachedFailures() async throws {
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"warp","account_ref":{"origin":"owned","id":"mirror","label":"__quotio_local_warp__:Work"},"account":{"id":"warp","label":"Work"},"windows":[]},{"provider":"warp","account_ref":{"origin":"owned","id":"monitor","label":"Personal"},"account":{"id":"warp","label":"Personal"},"windows":[]}],"failures":[{"provider":"warp","account_ref":{"origin":"owned","id":"monitor-failed","label":"Personal failed"},"code":"authentication"},{"provider":"warp","account_ref":{"origin":"owned","id":"mirror-failed","label":"__quotio_local_warp__:Work failed"},"code":"authentication"}]}"#
        QuotioCLIURLProtocol.enqueue(report)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"monitor","provider":"warp","label":"Personal","origin":"owned","enabled":true},{"id":"mirror","provider":"warp","label":"__quotio_local_warp__:Work","origin":"owned","enabled":true}]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test-token"))
        let snapshot = await backend.bootstrap(mode: .localProxy)
        XCTAssertEqual(Set(snapshot.quotas[.warp]?.keys.map { $0 } ?? []), ["Work"])
        XCTAssertEqual(Set(snapshot.accountIDs[.warp]?.values.map { $0 } ?? []), ["mirror", "mirror-failed"])
        XCTAssertEqual(Set(snapshot.accountIssues.keys.map(\.accountKey)), ["Work failed"])
        let accounts = await backend.accounts()
        XCTAssertEqual(Set(accounts.map(\.id)), ["mirror", "mirror-failed"])
        await backend.disconnect()
        let cached = await backend.accounts()
        XCTAssertEqual(Set(cached.map(\.id)), ["mirror", "mirror-failed"])

        let decoded = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: Data(report.utf8))
        let monitor = QuotioCLIUsageMapper.snapshot(decoded, mode: .monitor)
        XCTAssertEqual(monitor.quotas[.warp]?.count, 2)
        XCTAssertEqual(monitor.accountIssues.count, 2)
    }

    func testLocalWarpMirrorsAreReadOnlyWhileManagedWarpAccountsRemainEditable() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"managed","provider":"warp","label":"Managed","origin":"owned","enabled":true},{"id":"mirror","provider":"warp","label":"__quotio_local_warp__:Work","origin":"owned","enabled":true}]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))

        let accounts = await backend.accounts()

        let mirror = try XCTUnwrap(accounts.first { $0.id == "mirror" })
        XCTAssertEqual(mirror.displayName, "Work")
        XCTAssertTrue(mirror.capabilities.isEmpty)
        XCTAssertEqual(accounts.first { $0.id == "managed" }?.capabilities, [.disable, .edit, .delete])
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

    func testCustomProviderReferencesAreReadOnly() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"glm","provider":"zai","label":"GLM","origin":"borrowed_proxy","enabled":true,"source_kind":"quotio_custom_provider"},{"id":"cline","provider":"clinepass","label":"Cline","origin":"borrowed_proxy","enabled":true,"source_kind":"quotio_custom_provider"},{"id":"owned","provider":"zai","label":"Owned","origin":"owned","enabled":true}]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test-token"))
        let accounts = await backend.accounts()
        XCTAssertEqual(accounts.count, 3)
        XCTAssertTrue(accounts.filter { $0.id != "owned" }.allSatisfy { $0.capabilities.isEmpty })
        XCTAssertEqual(accounts.first { $0.id == "owned" }?.capabilities, [.disable, .edit, .delete])
    }

    func testRefreshReenablesReferenceWhoseCustomProviderIsEnabled() async throws {
        let provider = CustomProvider(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Work Z.ai", type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "secret")]
        )
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"custom-1","provider":"zai","label":"Work Z.ai","origin":"borrowed_proxy","enabled":false,"source_kind":"quotio_custom_provider","source_id":"8c5323370293dc7d3ad3b61ed18ce2bb8191ebc3e743d93fdc5e5b6d8504c20e"}]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"enable","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession(), customProviders: { [provider] }, customProviderDomain: "com.example.quotio")
        await backend.connect(QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test-token"))
        _ = await backend.refresh(QuotaFetchRequest(provider: .glm, mode: .monitor))
        let data = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/accounts/custom-1"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["enabled": true])
        XCTAssertEqual(QuotioCLIURLProtocol.requests().map { $0.url!.path }, ["/v1/accounts", "/v1/accounts/custom-1", "/v1/refresh", "/v1/usage"])
    }

    func testRefreshKeepsMatchingCustomProviderReference() async throws {
        let provider = CustomProvider(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Work Z.ai",
            type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "secret")]
        )
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"custom-1","provider":"zai","label":"Work Z.ai","origin":"borrowed_proxy","enabled":true,"source_kind":"quotio_custom_provider","source_id":"8c5323370293dc7d3ad3b61ed18ce2bb8191ebc3e743d93fdc5e5b6d8504c20e"}]}"#)
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
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"custom-1","provider":"zai","label":"Work Z.ai","origin":"borrowed_proxy","enabled":true,"source_kind":"quotio_custom_provider","source_id":"8c5323370293dc7d3ad3b61ed18ce2bb8191ebc3e743d93fdc5e5b6d8504c20e"}]}"#)
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

    func testUsageDiagnosticsArePartialButRetainedQuotaFailuresAreFailed() throws {
        for diagnostics in ["[]", #"[{"source":"supplemental","code":"transient"}]"#] {
            for extraFailure in ["", #",{"provider":"openrouter","account_ref":{"id":"work","label":"Work"},"code":"authentication"}"#] {
                let data = Data(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"openrouter","account_ref":{"id":"work","label":"Work"},"account":{"id":"user","label":"Work"},"windows":[],"diagnostics":\#(diagnostics)}],"failures":[{"provider":"openrouter","account_ref":{"id":"work","label":"Work"},"code":"transient"}\#(extraFailure)]}"#.utf8)
                let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
                let snapshot = QuotioCLIUsageMapper.snapshot(report)
                let issue = snapshot.accountIssues[QuotaAccountID(provider: .openRouter, accountKey: "Work")]
                XCTAssertEqual(issue?.kind, diagnostics == "[]" || !extraFailure.isEmpty ? .failed : .partial)
            }
        }
    }

    func testBootstrapRestoresImportedIDEQuotaSelectionWhileHelperIsNotReady() async throws {
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
        QuotioCLIURLProtocol.enqueue(#"{"error":"not_ready"}"#, status: 503)
        let backend = QuotioCLIBackend(session: stubSession(), userDefaults: defaults)
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        let snapshot = await backend.bootstrap(mode: .monitor)

        XCTAssertEqual(snapshot.quotas[.cursor]?["person@example.com"], quota)
        XCTAssertNil(snapshot.quotas[.trae])
        XCTAssertEqual(snapshot.issues[.cursor]?.kind, .failed)

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

    func testDisabledProxyFilesFilterRefreshAndPersistedSnapshotsWithoutHidingOwnedAccount() async throws {
        let suite = "QuotioCLIBackendTests.disabled.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = UserDefaultsManagedAuthFileStateRepository(defaults: defaults)
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned","label":"Work"},"account":{"id":"owned","label":"Work"},"windows":[]},{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"44ca7be0ce2c2f800a2fec0aa175c36b09f09b0ad21c7fecc83e4c345853a93d","label":"Work"},"account":{"id":"proxy","label":"Work"},"windows":[]}],"failures":[{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"f7ff9ce8cb0a99488cf1712149ff9879ef7bbc2353795f901e76e286270c2fe1","label":"Failed"},"code":"authentication"}]}"#
        let disabledID = "44ca7be0ce2c2f800a2fec0aa175c36b09f09b0ad21c7fecc83e4c345853a93d"
        let backend = QuotioCLIBackend(session: stubSession(), userDefaults: UserDefaults(suiteName: suite)!, authFileState: state)
        let connection = QuotioCLIConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test-token")
        await backend.connect(connection)
        QuotioCLIURLProtocol.enqueue(report)
        let before = await backend.bootstrap(mode: .monitor)
        XCTAssertEqual(before.quotas[.claude]?.count, 2)
        state.saveDisabledAuthFileNames(["claude-work.json", "claude-failed.json"])

        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(report)
        let snapshot = await backend.refresh(QuotaFetchRequest(provider: .claude, scope: .account(disabledID), mode: .monitor))
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/refresh"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["account_id"] as? String, disabledID)
        XCTAssertEqual(json["disabled_proxy_auth_files"] as? [String], ["claude-failed.json", "claude-work.json"])
        XCTAssertEqual(snapshot.accountIDs[.claude], ["Work": "owned"])
        XCTAssertEqual(snapshot.accountAliases[.claude], ["Work": "Work", "owned": "Work"])
        XCTAssertTrue(snapshot.accountIssues.isEmpty)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[]}"#)
        let accounts = await backend.accounts()
        XCTAssertEqual(accounts.map(\.id), ["owned"])

        let restarted = QuotioCLIBackend(session: stubSession(), userDefaults: UserDefaults(suiteName: suite)!, authFileState: UserDefaultsManagedAuthFileStateRepository(defaults: defaults))
        await restarted.connect(connection)
        QuotioCLIURLProtocol.enqueue(report)
        let restored = await restarted.bootstrap(mode: .localProxy)
        XCTAssertTrue(restored.quotas.isEmpty)
        XCTAssertTrue(restored.accountAliases.isEmpty)
        XCTAssertTrue(restored.accountIssues.isEmpty)
        state.saveDisabledAuthFileNames([])
        QuotioCLIURLProtocol.enqueue(report)
        let reenabled = await restarted.bootstrap(mode: .localProxy)
        XCTAssertEqual(reenabled.quotas[.claude]?.count, 1)
        XCTAssertEqual(reenabled.accountIssues.count, 1)
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
    nonisolated(unsafe) private static var bodies: [(Data, Int)] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var recordedBodies: [Data?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestBody = Self.readBody(from: request)
        let (body, status) = Self.lock.withLock { () -> (Data, Int) in
            Self.recordedRequests.append(request)
            Self.recordedBodies.append(requestBody)
            return Self.bodies.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(_ body: String, status: Int = 200) {
        lock.withLock { bodies.append((Data(body.utf8), status)) }
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
