import QuotioHostClient
import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class QuotioCLIBackendTests: XCTestCase {
    func testHostMetricGroupsAreForwardedWithoutProviderRules() throws {
        let fixture = try hostFixture { root in
            var usage = root["usage"] as! [[String: Any]]
            var metrics = usage[1]["metrics"] as! [[String: Any]]
            metrics[0]["group"] = "Custom pool"
            usage[1]["metrics"] = metrics
            root["usage"] = usage
        }
        let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
        let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
        XCTAssertEqual(snapshot.quotas[.devin]?["devin-desktop-account"]?.models.first?.group, "Custom pool")
    }

    func testRefreshAvailabilityComesFromTheHostCapability() throws {
        for allowed in [false, true] {
            let fixture = try hostFixture { root in
                var host = root["host"] as! [String: Any]
                var capabilities = host["capabilities"] as! [String: Any]
                capabilities["refresh"] = ["available": allowed]
                host["capabilities"] = capabilities
                root["host"] = host
            }
            let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
            XCTAssertEqual(QuotioHostPresentationMapper.resolvedSnapshot(host).canRefresh, allowed)
        }
    }

    func testQuotaSummaryUsesHostValuesWithoutRecomputingFromMetrics() throws {
        for lowest in [17, 101] {
            let fixture = try hostFixture { root in
                var usage = root["usage"] as! [[String: Any]]
                usage[1]["summary"] = [
                    "session_only": ["lowest": lowest, "average": 33],
                    "combined": ["lowest": 72, "average": 84],
                    "pair": [["display_name": "Host metric", "remaining_percent": 17],
                             ["display_name": "Unknown", "remaining_percent": NSNull()]],
                ]
                root["usage"] = usage
            }
            if lowest > 100 {
                XCTAssertThrowsError(try QuotioHostSnapshot.decode(Data(fixture.utf8)))
                continue
            }
            let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
            let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
            let summaries = snapshot.quotas.values.flatMap { $0.values }.compactMap(\.summary)
            let summary = try XCTUnwrap(summaries.first)
            XCTAssertEqual(summary.sessionOnly.lowest, 17)
            XCTAssertEqual(summary.combined.average, 84)
            XCTAssertEqual(summary.pair[0].displayName, "Host metric")
            XCTAssertNil(summary.pair[1].remainingPercent)
        }
    }

    func testResolvedMutationsPreserveAccountAndSourceScopesAndExplicitNameReset() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        for _ in 0..<4 { QuotioCLIURLProtocol.enqueue(#"{"id":"operation","status":"completed"}"#) }
        try await backend.renameResolvedAccount(id: "logical", userLabel: nil)
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/accounts/logical"))
        let reset = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(reset["user_label"] is NSNull)
        XCTAssertEqual(reset.count, 1)
        try await backend.setResolvedEnabled(false, target: .account("logical"))
        try await backend.setSourceEnabled(false, sourceID: "source")
        try await backend.unlinkSource(sourceID: "source")
        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v2/accounts/logical", "/v2/accounts/logical", "/v2/sources/source", "/v2/sources/source"])
        XCTAssertEqual(requests.map(\.httpMethod), ["PATCH", "PATCH", "PATCH", "DELETE"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") != nil })
    }

    func testAccountAndSourceActionsAreForwardedForFrontendCRUD() async throws {
        QuotioCLIURLProtocol.enqueue(try hostFixture { root in
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[0]["actions"] = [["kind":"rename", "available":true, "reason":NSNull(), "interaction":"client"]]
            var sources = accounts[0]["sources"] as! [[String: Any]]
            sources[0]["enabled"] = false
            sources[0]["selected"] = false
            sources[0]["actions"] = [["kind":"set_source_enabled", "available":true, "reason":NSNull(), "interaction":"host"], ["kind":"remove_source", "available":false, "reason":"read_only", "interaction":"host"]]
            accounts[0]["sources"] = sources
            root["accounts"] = accounts
            root["usage"] = []
        })
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let accounts = await backend.accounts()
        XCTAssertTrue(try XCTUnwrap(accounts.first).capabilities.contains(.rename))
        let source = try XCTUnwrap(accounts.first?.sources.first)
        XCTAssertEqual(accounts.first?.isIdentityVerified, true)
        XCTAssertEqual(source.enabled, false)
        XCTAssertEqual(source.actions, ["set_source_enabled"])
    }

    func testResolvedAccountReadUsesRustNamesGroupsAndActionsUnchanged() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../").standardizedFileURL
        let data = try Data(contentsOf: root.appendingPathComponent("apps/cli/tests/fixtures/contracts/accounts-v2.json"))
        QuotioCLIURLProtocol.enqueue(try XCTUnwrap(String(data: data, encoding: .utf8)))
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let result = try await backend.resolvedAccounts()
        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.accounts[0].id, "source-a")
        XCTAssertEqual(result.accounts[0].displayName, "Work")
        XCTAssertEqual(result.accounts[0].sources.count, 2)
        XCTAssertEqual(result.accounts[0].actions.map(\.kind), ["rename", "set_enabled", "select", "remove"])
        XCTAssertEqual(result.accounts[0].state, "not_checked")
        XCTAssertEqual(QuotioCLIURLProtocol.requests().last?.url?.path, "/v2/accounts")
        var incompatible = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        incompatible["schema_version"] = 3
        QuotioCLIURLProtocol.enqueue(try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: incompatible), encoding: .utf8)))
        do {
            _ = try await backend.resolvedAccounts()
            XCTFail("Unsupported contract must not reach the frontend")
        } catch QuotioHostClientError.incompatible {}
    }

    func testSuccessfulAccountReadClearsPreviousStoragePermissionFailure() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        QuotioCLIURLProtocol.enqueue(#"{"error":"credential_storage_unavailable"}"#, status: 503)
        _ = await backend.accounts()
        let blocked = await backend.accountStorageRequiresAuthorization()
        XCTAssertTrue(blocked)
        QuotioCLIURLProtocol.enqueue(try hostFixture { $0["accounts"] = []; $0["usage"] = [] })
        _ = await backend.accounts()
        let recovered = await backend.accountStorageRequiresAuthorization()
        XCTAssertFalse(recovered)
    }

    func testKeychainAuthorizationForwardsTheHostSelectedAccount() async throws {
        for source in [
            NativeSourcePermission(provider: .copilot, kind: "copilot_native", location: "gh_keychain", keychainAccount: "selected-user"),
            NativeSourcePermission(provider: .factoryDroid, kind: "factory_native", location: "v2_keyring", keychainAccount: "auth-encryption-key"),
        ] {
            let backend = QuotioCLIBackend(session: stubSession())
            await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
            QuotioCLIURLProtocol.enqueue(#"{"id":"authorize","status":"failed","error":"native_keychain_access_failed"}"#)
            do {
                try await backend.authorizeNativeSource(source)
                XCTFail("Expected the supplied failure")
            } catch {}
            let data = try XCTUnwrap(QuotioCLIURLProtocol.bodies(forPath: "/v2/sources/authorize").last)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(value["entry_key"], source.keychainAccount)
        }
    }

    func testAuthorizationFailurePreservesItsVerifiedStage() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        for (code, expected) in [
            ("quotio_vault_access_failed", NativeSourceAuthorizationFailure.quotioVault),
            ("native_keychain_access_failed", .nativeKeychain),
            ("native_login_required", .nativeLogin),
            ("native_credential_invalid", .invalidCredential),
        ] {
            QuotioCLIURLProtocol.enqueue("{\"id\":\"authorize\",\"status\":\"failed\",\"error\":\"\(code)\"}")
            do {
                try await backend.authorizeNativeSource(.init(provider: .antigravity, kind: "antigravity_native", location: "gemini_keychain"))
                XCTFail("Expected a stage-specific failure")
            } catch let failure as NativeSourceAuthorizationFailure {
                XCTAssertEqual(failure, expected)
            }
        }
    }

    func testCanonicalDevinProvidersRemainDistinctAndRouteWithoutAliases() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let entries = ["devin", "devin-desktop"].map { id in
            ["id": id, "display_name": id, "actions": [], "capabilities": ["operations": [], "settings": []]] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 2, "providers": entries])
        QuotioCLIURLProtocol.enqueue(String(decoding: data, as: UTF8.self))
        let providers = try await backend.monitoringProviders()
        XCTAssertEqual(Set(providers.map(\.id.rawValue)), ["devin", "devin-desktop"])
        QuotioCLIURLProtocol.enqueue(#"{"id":"create","status":"completed"}"#)
        try await backend.saveAPIKey(providerID: .init(rawValue: "devin"), label: "Cloud", apiKey: "fixture", existingAccountID: nil)
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/accounts"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["provider"] as? String, "devin")
    }

    func testProviderCatalogKeepsUnknownProvidersAndUsesHostActions() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":2,"providers":[{"id":"future-provider","display_name":"Future Provider","actions":[{"kind":"add_api_key","available":true,"reason":null,"interaction":"client"},{"kind":"start_oauth","available":false,"reason":"unsupported_platform","interaction":"host_user"}],"capabilities":{"operations":["usage"],"settings":[{"name":"organization","field_path":"settings.organization","required":true}]}}]}"#)
        let providers = try await backend.monitoringProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].id.rawValue, "future-provider")
        XCTAssertEqual(providers[0].displayName, "Future Provider")
        XCTAssertEqual(providers[0].actions, ["add_api_key"])
        XCTAssertEqual(providers[0].inputs.first?.fieldPath, "settings.organization")
        XCTAssertEqual(providers[0].inputs.first?.required, true)
        QuotioCLIURLProtocol.enqueue(try hostFixture())
        let snapshot = await backend.bootstrap(mode: .monitor)
        XCTAssertEqual(snapshot.providerNames[providers[0].id], "Future Provider")
        await backend.disconnect()
        let disconnected = await backend.snapshot
        XCTAssertEqual(disconnected.issues[providers[0].id]?.kind, .failed)
    }

    func testMonitoringSettingsAndDefaultScopesAreOwnedByHost() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let settings = #"{"revision":"first","enabled_providers":["codex","future-provider"],"disabled_providers":["future-provider"],"automatically_discover_logins":false,"refresh_interval":123,"overridden":[]}"#
        QuotioCLIURLProtocol.enqueue(settings)
        var value = try await backend.monitoringSettings()
        XCTAssertEqual(value.refreshInterval, 123)
        value.refreshInterval = 600
        QuotioCLIURLProtocol.enqueue(settings.replacingOccurrences(of: "first", with: "second").replacingOccurrences(of: "123", with: "600"))
        let updated = try await backend.updateMonitoringSettings(value)
        XCTAssertEqual(updated.revision, "second")
        let data = try XCTUnwrap(QuotioCLIURLProtocol.bodies(forPath: "/v2/settings").last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["revision"] as? String, "first")
        XCTAssertEqual(body["disabled_providers"] as? [String], ["future-provider"])
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(try hostFixture())
        _ = await backend.refreshAll(mode: .monitor)
        let refreshData = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/refresh"))
        let refresh = try XCTUnwrap(JSONSerialization.jsonObject(with: refreshData) as? [String: Any])
        XCTAssertEqual(refresh["providers"] as? [String], [])
        QuotioCLIURLProtocol.enqueue(#"{"id":"scan","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(discoveryFixture())
        await backend.registerDetectedNativeAccounts()
        let scanData = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/discovery"))
        let scan = try XCTUnwrap(JSONSerialization.jsonObject(with: scanData) as? [String: Any])
        XCTAssertEqual(scan["providers"] as? [String], [])
    }

    override func tearDown() {
        QuotioCLIURLProtocol.reset()
        super.tearDown()
    }

    func testUsageReportMapsCodexAnalyticsAndResetCredits() throws {
        let data = Data(#"""
        {
          "schema_version": 2,
          "host": {
            "id": "host-fixture",
            "platform": "macos",
            "api_versions": [
              1,
              2
            ],
            "capabilities": {
              "native_authorization": {
                "available": true,
                "reason": null
              }
            }
          },
          "revision": 7,
          "generated_at": "2026-09-24T00:00:00Z",
          "accounts": [
            {
              "id": "codex-account",
              "provider_id": "codex",
              "display_name": "Codex User",
              "user_label": null,
              "identity": {
                "evidence": "verified",
                "username": "fixture-user",
                "email": null
              },
              "enabled": true,
              "state": "ready",
              "sources": [
                {
                  "id": "codex-source",
                  "origin": "owned",
                  "kind": "owned_credential",
                  "location": "gh_keychain",
                  "enabled": true,
                  "selected": true,
                  "state": "ready",
                  "refresh_owner": "provider_tool",
                  "issue": null,
                  "actions": []
                }
              ],
              "actions": [
                {
                  "kind": "refresh",
                  "available": true,
                  "reason": null,
                  "interaction": "host"
                }
              ],
              "active": true
            }
          ],
          "usage": [
            {
              "account_id": "codex-account",
              "freshness": "fresh",
              "fetched_at": "2026-09-16T12:00:00Z",
              "expires_at": "2026-09-24T00:05:00Z",
              "plan": "plus",
              "metrics": [
                {
                  "id": "unlimited",
                  "display_name": "Unlimited",
                  "quota": {
                    "state": "unlimited"
                  },
                  "fetched_at": "2026-09-16T12:00:00Z",
                  "amounts": null,
                  "consumption": null,
                  "resets_at": null,
                  "reset_description": null,
                  "provenance": {
                    "source": "fixture",
                    "confidence": "exact"
                  }
                },
                {
                  "id": "disabled",
                  "display_name": "Disabled",
                  "quota": {
                    "state": "disabled"
                  },
                  "fetched_at": "2026-09-16T12:00:00Z",
                  "amounts": null,
                  "consumption": null,
                  "resets_at": null,
                  "reset_description": null,
                  "provenance": {
                    "source": "fixture",
                    "confidence": "exact"
                  }
                },
                {
                  "id": "limit",
                  "display_name": "Limit",
                  "quota": {
                    "state": "limit",
                    "amount": 5,
                    "unit": "USD"
                  },
                  "fetched_at": "2026-09-16T12:00:00Z",
                  "amounts": null,
                  "consumption": null,
                  "resets_at": null,
                  "reset_description": null,
                  "provenance": {
                    "source": "fixture",
                    "confidence": "exact"
                  }
                }
              ],
              "issue": null,
              "codex_profile": {
                "daily_usage": [
                  {
                    "date": "2026-09-15",
                    "tokens": 1200
                  }
                ],
                "latest_30_buckets_tokens": 1200,
                "lifetime_tokens": 8000,
                "peak_daily_tokens": 1200,
                "longest_running_turn_seconds": 3661,
                "current_streak_days": 1,
                "longest_streak_days": 3,
                "fetched_at": "2026-09-16T11:00:00Z"
              },
              "codex_reset_credits": {
                "available_count": 2,
                "credits": [
                  {
                    "id": "hashed-credit",
                    "expires_at": "2026-09-18T12:00:00Z"
                  }
                ],
                "fetched_at": "2026-09-16T11:30:00Z"
              }
            }
          ]
        }
        """#.utf8)

        let report = try QuotioHostSnapshot.decode(data)
        let quota = try XCTUnwrap(QuotioHostPresentationMapper.resolvedSnapshot(report).quotas[.codex]?["codex-account"])

        XCTAssertEqual(quota.lastUpdated, ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z"))
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
        let localized = try XCTUnwrap(QuotioHostPresentationMapper.resolvedSnapshot(report, bundle: bundle, locale: Locale(identifier: "fr")).quotas[.codex]?["codex-account"])
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
        await backend.connect(QuotioHostConnection(
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
        XCTAssertEqual(request.url?.path, "/v2/accounts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testAPIKeyFieldsUseDeclaredPathsAndCannotOverwriteTheCredential() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        do {
            try await backend.saveAPIKey(providerID: .init(rawValue: "future-provider"), label: "Work", apiKey: "fixture", existingAccountID: nil, fields: ["api_key": "override"])
            XCTFail("Unexpected field path accepted")
        } catch {}
        XCTAssertTrue(QuotioCLIURLProtocol.requests().isEmpty)
        QuotioCLIURLProtocol.enqueue(#"{"id":"create","status":"completed"}"#)
        try await backend.saveAPIKey(providerID: .init(rawValue: "future-provider"), label: "Work", apiKey: "fixture", existingAccountID: nil, fields: ["region": "eu", "settings.organization": "team", "settings.optional": ""])
        let data = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/accounts"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["provider"] as? String, "future-provider")
        XCTAssertEqual(body["api_key"] as? String, "fixture")
        XCTAssertEqual(body["region"] as? String, "eu")
        XCTAssertEqual(body["settings"] as? [String: String], ["organization": "team"])
    }

    func testLegacyImportUsesStableReceiptAndUnixExpiry() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioHostConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        let account = Account.make(providerID: AccountProviderID(rawValue: "kiro"), accountKey: "Work", source: .quotioKeychain)
        let credential = StoredCredential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil, accountID: "user", expiresAt: Date(timeIntervalSince1970: 1_700_000_000.9), extra: ["authMethod": "IdC", "clientId": "synthetic-client", "clientSecret": "synthetic-secret"])
        for _ in 0..<2 {
            QuotioCLIURLProtocol.enqueue(#"{"id":"import","status":"completed"}"#)
            try await backend.importLegacyAccount(account, credential: credential, disabled: true)
        }
        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/migrations/accounts"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(value["enabled"] as? Bool, false)
        XCTAssertEqual(value["provider"] as? String, "kiro")
        let imported = try XCTUnwrap(value["credential"] as? [String: Any])
        XCTAssertEqual(imported["expires_at"] as? Int64, 1_700_000_000)
        XCTAssertEqual((imported["extra"] as? [String: String])?["clientSecret"], "synthetic-secret")
    }

    func testLegacyImportRejectsOutOfRangeExpiryWithoutSendingCredential() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioHostConnection(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "private-token"))
        let account = Account.make(providerID: AccountProviderID(rawValue: "claude"), accountKey: "Work", source: .quotioKeychain)
        let credential = StoredCredential(accessToken: "synthetic", refreshToken: "synthetic-refresh", idToken: nil, accountID: "user", expiresAt: Date(timeIntervalSince1970: 1e100), extra: [:])
        do {
            try await backend.importLegacyAccount(account, credential: credential, disabled: false)
            XCTFail("Invalid dates must be reported without trapping")
        } catch { }
        XCTAssertTrue(QuotioCLIURLProtocol.requests().isEmpty)
    }

    func testDeviceCodeExpiryComesFromHostStateAndCleansUpTheSession() async throws {
        let expired = Int64(Date().timeIntervalSince1970) + 3600
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"waiting","account_id":null,"error_code":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"expired","account_id":null,"error_code":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"expired","account_id":null,"error_code":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioHostConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))
        let authorizer = QuotioCLIOAuthAuthorizer(
            backend: backend,
            urlOpener: QuotioCLIURLOpenerStub()
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
        XCTAssertEqual(QuotioCLIURLProtocol.requests().count, 3)
        XCTAssertEqual(QuotioCLIURLProtocol.requests().last?.httpMethod, "DELETE")
    }

    func testOAuthCallbackUsesExchangeTimeout() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"provider":"codex","workflow":"browser_redirect","user_code":null,"id":"session-1","url":"https://example.com","expires_at":4102444800,"status":"completed","account_id":"account-1","error_code":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioHostConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        _ = try await backend.completeOAuth(id: "session-1", code: "code")

        XCTAssertEqual(QuotioCLIURLProtocol.requests().first?.timeoutInterval, 60)
    }

    func testBrowserOAuthUsesHostListenerAndReturnsBackendAccountMetadata() async throws {
        let waiting = #"{"provider":"codex","workflow":"browser_callback","id":"session","url":"https://auth.example.test/authorize","expires_at":4102444800,"status":"waiting"}"#
        QuotioCLIURLProtocol.enqueue(waiting)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"codex","workflow":"browser_callback","id":"session","url":"https://auth.example.test/authorize","expires_at":4102444800,"status":"completed","account_id":"source-a"}"#)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../").standardizedFileURL
        let data = try Data(contentsOf: root.appendingPathComponent("apps/cli/tests/fixtures/contracts/accounts-v2.json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var account = (envelope["accounts"] as! [[String: Any]])[0]
        account["provider_id"] = "codex"; account["display_name"] = "Backend account name"
        QuotioCLIURLProtocol.enqueue(try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: account), encoding: .utf8)))
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let authorizer = QuotioCLIOAuthAuthorizer(backend: backend, urlOpener: QuotioCLIURLOpenerStub())
        let outcome = try await authorizer.begin(request: .init(providerID: .init(rawValue: "codex")), attemptID: .init(), progress: { _ in })
        guard case .completed(let result) = outcome else { return XCTFail("Expected completion") }
        XCTAssertEqual(result.id, "source-a")
        XCTAssertEqual(result.displayName, "Backend account name")
        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v2/auth/sessions", "/v2/auth/sessions/session", "/v2/accounts/source-a"])
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/auth/sessions"))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(input, ["provider":"codex"])
    }

    private func discoveryFixture(permission: Bool = false) -> String {
        #"{"schema_version":2,"scans":[{"provider":"copilot","at":"2026-01-01T00:00:00Z"}],"permissions":\#(permission ? #"[{"provider":"copilot","kind":"copilot_native","location":"gh_keychain"}]"# : "[]"),"known_sources":[],"failures":[],"registered":0}"#
    }

    func testDiscoveryDelegatesScanningAndPermissionDecisionsToTheHost() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"id":"scan","status":"completed"}"#)
        for _ in 0..<2 { QuotioCLIURLProtocol.enqueue(discoveryFixture(permission: true)) }
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        await backend.registerDetectedNativeAccounts()
        let discovery = await backend.nativeDiscoverySnapshot()
        let pending = discovery.permissions
        let known = discovery.knownSources
        let dates = discovery.scannedAt
        XCTAssertEqual(pending, [.init(provider: .copilot, kind: "copilot_native", location: "gh_keychain")])
        XCTAssertTrue(known.isEmpty)
        XCTAssertEqual(dates[.copilot], ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        XCTAssertTrue(QuotioCLIURLProtocol.requests().allSatisfy { $0.url?.path == "/v2/discovery" })
        XCTAssertEqual(QuotioCLIURLProtocol.requests().map(\.httpMethod), ["POST", "GET", "GET"])
    }

    func testDiscoveryStoreDenialIsReportedAndGrantingAccessRetriesTheHost() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"error":"credential_storage_unavailable"}"#, status: 503)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        await backend.registerDetectedNativeAccounts()
        let denied = await backend.accountStorageRequiresAuthorization()
        XCTAssertTrue(denied)
        QuotioCLIURLProtocol.enqueue(#"{"id":"authorize","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"scan","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(discoveryFixture())
        try await backend.authorizeAccountStorage()
        let recovered = await backend.accountStorageRequiresAuthorization()
        XCTAssertFalse(recovered)
        XCTAssertEqual(QuotioCLIURLProtocol.requests().map { $0.url?.path }, ["/v2/discovery", "/v2/account-vault/authorize", "/v2/discovery", "/v2/discovery"])
    }

    func testExplicitAuthorizationRefreshesOnlyTheRequestedProviderDiscovery() async throws {
        QuotioCLIURLProtocol.enqueue(discoveryFixture(permission: true))
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let pending = await backend.nativeDiscoverySnapshot().permissions
        XCTAssertEqual(QuotioCLIURLProtocol.requests().count, 1)
        QuotioCLIURLProtocol.enqueue(#"{"id":"authorize","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"scan","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(discoveryFixture())
        try await backend.authorizeNativeSource(try XCTUnwrap(pending.first))
        let data = try XCTUnwrap(QuotioCLIURLProtocol.bodies(forPath: "/v2/discovery").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["providers"] as? [String], ["copilot"])
        XCTAssertEqual(QuotioCLIURLProtocol.requests().filter { $0.url?.path == "/v2/sources/authorize" }.count, 1)
    }

    func testOnlyAnExplicitRescanRequestsRestorationOfRemovedSources() async throws {
        for _ in 0..<2 {
            QuotioCLIURLProtocol.enqueue(#"{"id":"scan","status":"completed"}"#)
            QuotioCLIURLProtocol.enqueue(discoveryFixture())
        }
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        await backend.registerDetectedNativeAccounts()
        await backend.rescanNativeAccounts(for: .copilot)
        let bodies = try QuotioCLIURLProtocol.bodies(forPath: "/v2/discovery").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["restore_removed"] as? Bool, false)
        XCTAssertEqual(bodies[1]["restore_removed"] as? Bool, true)
        XCTAssertEqual(bodies[1]["providers"] as? [String], ["copilot"])
    }

    private func hostFixture(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../").standardizedFileURL
        let data = try Data(contentsOf: root.appendingPathComponent("apps/cli/tests/fixtures/contracts/snapshot-v2.json"))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&value)
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
    }

    func testSnapshotReadPreservesRustNamesGroupsMetricsAndSourceSelection() async throws {
        let fixture = try hostFixture()
        QuotioCLIURLProtocol.enqueue(fixture)
        QuotioCLIURLProtocol.enqueue(fixture)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let snapshot = await backend.bootstrap(mode: .monitor)
        let accounts = await backend.accounts()
        XCTAssertEqual(accounts.map(\.id), ["copilot-account", "devin-desktop-account"])
        XCTAssertEqual(accounts.map(\.displayName), ["fixture-user", "person@example.test"])
        XCTAssertEqual(accounts[1].sources.count, 2)
        XCTAssertEqual(snapshot.accountIDs[.devin]?["devin-desktop-account"], "devin-desktop-source-0")
        XCTAssertEqual(snapshot.quotas[.devin]?["devin-desktop-account"]?.models.first?.percentage, 75)
        XCTAssertEqual(snapshot.quotas[.devin]?["devin-desktop-account"]?.models.first?.id, "weekly")
        XCTAssertEqual(snapshot.quotas[.copilot]?["copilot-account"]?.planType, "Business")
        XCTAssertTrue(snapshot.quotas[.copilot]?["copilot-account"]?.models.isEmpty == true)
        XCTAssertEqual(QuotioCLIURLProtocol.requests().map { $0.url?.path }, ["/v2/snapshot", "/v2/snapshot"])
    }

    func testSnapshotDoesNotMergeEqualDisplayNamesOrRecomputeFreshness() async throws {
        let fixture = try hostFixture { root in
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[1]["provider_id"] = "copilot"
            accounts[1]["display_name"] = "fixture-user"
            root["accounts"] = accounts
            var usage = root["usage"] as! [[String: Any]]
            usage[0]["freshness"] = "stale"
            usage[1]["freshness"] = "fresh"
            usage[1]["fetched_at"] = "2000-01-01T00:00:00Z"
            root["usage"] = usage
        }
        let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
        let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
        XCTAssertEqual(snapshot.quotas[.copilot]?.count, 2)
        XCTAssertEqual(snapshot.accountStates[.init(provider: .copilot, accountKey: "copilot-account")]?.quota, .stale)
        XCTAssertEqual(snapshot.accountStates[.init(provider: .copilot, accountKey: "devin-desktop-account")]?.quota, .fresh)
    }

    func testOlderRevisionCannotReplaceNewerHostStateAndReconnectClearsIt() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        QuotioCLIURLProtocol.enqueue(try hostFixture())
        _ = await backend.bootstrap(mode: .monitor)
        QuotioCLIURLProtocol.enqueue(try hostFixture { root in
            root["revision"] = 6; root["accounts"] = []; root["usage"] = []
        })
        let retained = await backend.accounts()
        XCTAssertEqual(retained.count, 2)
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43211")!, token: "second"))
        QuotioCLIURLProtocol.enqueue(try hostFixture { root in
            root["revision"] = 1; root["accounts"] = []; root["usage"] = []
            var host = root["host"] as! [String: Any]; host["id"] = "another-host"; root["host"] = host
        })
        let replaced = await backend.accounts()
        XCTAssertTrue(replaced.isEmpty)
    }

    func testRefreshUsesLogicalIDAndAcceptsTheFullHostSnapshot() async throws {
        let fixture = try hostFixture()
        QuotioCLIURLProtocol.enqueue(fixture)
        QuotioCLIURLProtocol.enqueue(#"{"id":"refresh","status":"completed"}"#)
        QuotioCLIURLProtocol.enqueue(fixture)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        _ = await backend.bootstrap(mode: .monitor)
        let result = await backend.refresh(.init(provider: .devin, scope: .account("devin-desktop-account"), mode: .monitor))
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/refresh"))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(request["account_id"] as? String, "devin-desktop-account")
        XCTAssertNotNil(result.quotas[.copilot]?["copilot-account"])
        XCTAssertNotNil(result.quotas[.devin]?["devin-desktop-account"])
    }

    func testFailedProbeKeepsProviderIssueWithoutInventingAccounts() async throws {
        let fixture = try hostFixture { root in
            root["accounts"] = []; root["usage"] = []
            root["provider_issues"] = ["claude": ["code": "authentication", "retryable": false, "action": NSNull()]]
        }
        QuotioCLIURLProtocol.enqueue(fixture); QuotioCLIURLProtocol.enqueue(fixture)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let snapshot = await backend.bootstrap(mode: .monitor)
        let accounts = await backend.accounts()
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(snapshot.issues[.claude]?.reason, .authentication)
    }

    func testHostDisabledStateAndActionsAreNotInferredFromSourceKind() async throws {
        let fixture = try hostFixture { root in
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[0]["enabled"] = false; accounts[0]["state"] = "disabled"
            accounts[0]["actions"] = [["kind":"remove", "available":true, "reason":NSNull(), "interaction":"host"]]
            var sources = accounts[0]["sources"] as! [[String: Any]]
            sources[0]["enabled"] = false; sources[0]["selected"] = false; sources[0]["state"] = "disabled"
            accounts[0]["sources"] = sources; root["accounts"] = accounts
        }
        QuotioCLIURLProtocol.enqueue(fixture)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let accounts = await backend.accounts()
        XCTAssertTrue(accounts[0].isDisabled)
        XCTAssertEqual(accounts[0].capabilities, [.delete])
        XCTAssertTrue(accounts[1].capabilities.isEmpty)
    }

    func testUnchangedSnapshotDoesNotPublishAnAccountReloadLoop() async throws {
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let states = await backend.states()
        QuotioCLIURLProtocol.enqueue(try hostFixture())
        _ = await backend.bootstrap(mode: .monitor)
        QuotioCLIURLProtocol.enqueue(try hostFixture { $0["generated_at"] = "2026-09-24T00:00:01Z" })
        _ = await backend.accounts()
        QuotioCLIURLProtocol.enqueue(try hostFixture { root in
            root["revision"] = 8
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[0]["display_name"] = "New host name"
            root["accounts"] = accounts
        })
        _ = await backend.accounts()
        await backend.cancelForTermination()
        var received: [QuotaSnapshot] = []
        for await state in states { received.append(state) }
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received.last?.quotas[.copilot]?["copilot-account"]?.accountDisplayName, "New host name")
    }

    func testAPIKeyEditTargetsItsSourceWithoutOverridingHostNaming() async throws {
        QuotioCLIURLProtocol.enqueue(try hostFixture { root in
            var account = (root["accounts"] as! [[String: Any]])[0]
            account["id"] = "logical"; account["provider_id"] = "amp"
            var sources = account["sources"] as! [[String: Any]]
            sources[0]["origin"] = "owned"; sources[0]["kind"] = "owned_credential"
            sources[0]["actions"] = [["kind":"replace_api_key", "available":true, "reason":NSNull(), "interaction":"host"]]
            account["sources"] = sources; root["accounts"] = [account]; root["usage"] = []
        })
        QuotioCLIURLProtocol.enqueue(#"{"id":"replace","status":"completed","result":{"account_id":"new-logical"}}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        try await backend.saveAPIKey(providerID: .init(rawValue: "amp"), label: "Work", apiKey: "synthetic-key", existingAccountID: "logical")
        XCTAssertEqual(QuotioCLIURLProtocol.requests().map { $0.url?.path }, ["/v2/snapshot", "/v2/sources/copilot-source-0"])
        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v2/sources/copilot-source-0"))
        let update = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(update, ["api_key": "synthetic-key"])
    }

    func testRecoveryActionComesFromTheHostEvenForUnknownReasons() throws {
        for available in [true, false] {
            let fixture = try hostFixture { root in
                var usage = root["usage"] as! [[String: Any]]
                usage[0]["issue"] = ["code":"future_provider_error", "retryable":true,
                    "action":["kind":"retry", "available":available, "reason":NSNull(), "interaction":"host"]]
                root["usage"] = usage
            }
            let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
            let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
            let issue = snapshot.accountIssues[.init(provider: .copilot, accountKey: "copilot-account")]
            XCTAssertNil(issue?.reason)
            XCTAssertEqual(issue?.recoveryAction, available ? .retry : nil)
        }
    }

    func testNewUnitsRenderWithoutProviderRulesAndUnknownQuotaKindsStayUnsupported() throws {
        for state in ["unknown", "future_quota_kind"] {
            let fixture = try hostFixture { root in
                var usage = root["usage"] as! [[String: Any]]
                var metrics = usage[1]["metrics"] as! [[String: Any]]
                metrics[0]["quota"] = ["state":state]
                metrics[0]["amounts"] = ["remaining":42, "limit":NSNull(), "unit":"widgets"]
                usage[1]["metrics"] = metrics; root["usage"] = usage
            }
            let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
            let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
            let metric = try XCTUnwrap(snapshot.quotas[.devin]?["devin-desktop-account"]?.models.first)
            if state == "unknown" {
                XCTAssertEqual(metric.presentation, .amount(value: 42, unit: try XCTUnwrap(QuotaMetricUnit(rawValue: "widgets")), semantics: .balance))
            } else {
                XCTAssertEqual(metric.presentation, .status(text: "Unsupported"))
            }
        }
    }

    func testOwnerDisabledHealthDoesNotChangeTheHostEnabledFlag() async throws {
        QuotioCLIURLProtocol.enqueue(try hostFixture { root in
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[0]["state"] = "disabled"
            var sources = accounts[0]["sources"] as! [[String: Any]]
            sources[0]["state"] = "disabled"; sources[0]["selected"] = false
            accounts[0]["sources"] = sources; root["accounts"] = accounts
            var usage = root["usage"] as! [[String: Any]]
            usage[0]["freshness"] = "unavailable"
            usage[0]["issue"] = ["code":"source_disabled", "retryable":false, "action":NSNull()]
            root["usage"] = usage
        })
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(.init(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "test"))
        let accounts = await backend.accounts()
        XCTAssertEqual(accounts[0].status, .disabled)
        XCTAssertFalse(accounts[0].isDisabled)
        XCTAssertTrue(accounts[0].enabled)
    }

    func testDisplayedConsumptionUsesTheHostValueInsteadOfSubtractingBalance() throws {
        let fixture = try hostFixture { root in
            var usage = root["usage"] as! [[String: Any]]
            var metrics = usage[1]["metrics"] as! [[String: Any]]
            metrics[0]["amounts"] = ["remaining":42, "limit":100, "unit":"credits"]
            metrics[0]["consumption"] = ["used":70, "unit":"credits"]
            usage[1]["metrics"] = metrics; root["usage"] = usage
        }
        let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
        let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
        XCTAssertEqual(snapshot.quotas[.devin]?["devin-desktop-account"]?.models.first?.presentation,
            .progress(used: 70, limit: 100, unit: .credits))
    }

    func testLogicalRedirectsNeverFollowAReassignedSourceID() throws {
        let fixture = try hostFixture { root in
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[0]["id"] = "old-account"
            var oldSources = accounts[0]["sources"] as! [[String: Any]]
            oldSources[0]["id"] = "remaining-source"; accounts[0]["sources"] = oldSources
            accounts[1]["id"] = "new-account"; accounts[1]["provider_id"] = "copilot"
            var newSources = accounts[1]["sources"] as! [[String: Any]]
            newSources[0]["id"] = "old-account"; accounts[1]["sources"] = newSources
            root["accounts"] = accounts
            var usage = root["usage"] as! [[String: Any]]
            usage[0]["account_id"] = "old-account"; usage[1]["account_id"] = "new-account"
            root["usage"] = usage
            root["account_redirects"] = ["old-alias":"old-account"]
        }
        let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
        let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
        XCTAssertEqual(snapshot.accountAliases[.copilot]?["old-account"], "old-account")
        XCTAssertEqual(snapshot.accountAliases[.copilot]?["old-alias"], "old-account")
        XCTAssertEqual(snapshot.accountAliases[.copilot]?["new-account"], "new-account")
    }

    func testKnownZeroAnalyticsAreNotTurnedIntoMissingData() throws {
        let fixture = try hostFixture { root in
            var accounts = root["accounts"] as! [[String: Any]]
            accounts[0]["provider_id"] = "codex"; root["accounts"] = accounts
            var usage = root["usage"] as! [[String: Any]]
            usage[0]["codex_profile"] = ["daily_usage":[], "latest_30_buckets_tokens":0,
                "lifetime_tokens":0, "fetched_at":"2026-09-24T12:00:00Z"]
            root["usage"] = usage
        }
        let host = try QuotioHostSnapshot.decode(Data(fixture.utf8))
        let snapshot = QuotioHostPresentationMapper.resolvedSnapshot(host)
        let rows = try XCTUnwrap(snapshot.quotas[.codex]?["copilot-account"]?.analytics?.rows)
        XCTAssertEqual(rows.first { $0.id == "last-30-days" }?.value, "0 tokens")
        XCTAssertEqual(rows.first { $0.id == "codex-lifetime-tokens" }?.value, "0 tokens")
        XCTAssertNil(rows.first { $0.id == "codex-peak-daily" })
        XCTAssertEqual(rows.first { $0.id == "today" }?.isAvailable, false)
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

    static func bodies(forPath path: String) -> [Data] {
        lock.withLock {
            zip(recordedRequests, recordedBodies).compactMap {
                $0.0.url?.path == path ? $0.1 : nil
            }
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
