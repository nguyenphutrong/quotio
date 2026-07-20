import XCTest
import SQLite3
@testable import Quotio

final class MonitorRuntimeTests: XCTestCase {
    func testMonitorProvidersDoNotRequireInstalledCLI() {
        let providers: Set<AIProvider> = [.codex, .claude, .gemini, .devin, .grok, .openRouter]

        let filtered = StatusBarMenuBuilder.filterProviders(
            providers,
            isMonitorMode: true,
            isCLIInstalled: { _ in false }
        )

        XCTAssertEqual(Set(filtered), providers)
    }

    func testStatusBarIncludesEnabledMonitorAccountsWithoutQuota() {
        let enabled = MonitorAccount.make(
            provider: .claude,
            accountKey: "enabled@example.com",
            source: .nativeCredential
        )
        var disabled = MonitorAccount.make(
            provider: .gemini,
            accountKey: "disabled@example.com",
            source: .nativeCredential
        )
        disabled.isDisabled = true

        XCTAssertEqual(StatusBarMenuBuilder.monitorProviders([enabled, disabled]), Set([.claude]))
    }

    func testMonitorAccountSourcesUseLocalizationKeys() {
        XCTAssertEqual(
            Set(MonitorAccountSource.allCases.map(\.localizationKey)),
            Set([
                "monitor.source.quotio",
                "monitor.source.localLogin",
                "monitor.source.cliProxyFile",
                "monitor.source.localIDE",
                "monitor.source.apiKey",
            ])
        )
    }

    func testDiscoveryCanonicalizesNativeCodexAccountBeforeDeduplication() {
        let legacy = MonitorAccount.make(
            provider: .codex,
            accountKey: "same@example.com-pro",
            displayName: "same@example.com",
            source: .legacyCLIProxy
        )
        let native = MonitorAccount.make(
            provider: .codex,
            accountKey: "same@example.com",
            source: .nativeCredential
        )

        let canonicalNative = MonitorAccountDiscovery.canonicalizeCodexAccount(
            native,
            accountID: "account-1",
            aliases: ["account-1": "same@example.com-pro"]
        )
        let duplicate = MonitorAccountDiscovery.selectPreferred([legacy, canonicalNative])
        XCTAssertEqual(duplicate.count, 1)
        XCTAssertEqual(duplicate.first?.accountKey, "same@example.com-pro")
        XCTAssertEqual(duplicate.first?.source, .nativeCredential)

        let distinctNative = MonitorAccountDiscovery.canonicalizeCodexAccount(
            native,
            accountID: "account-2",
            aliases: ["account-1": "same@example.com-pro"]
        )
        XCTAssertEqual(MonitorAccountDiscovery.selectPreferred([legacy, distinctNative]).count, 2)
    }

    func testCodexQuotaReconciliationRemovesOnlyLegacyAliases() {
        let quota = ProviderQuotaData(models: [], lastUpdated: Date())
        let legacy = [
            CodexQuotaAccountIdentity(
                key: "same@example.com-pro",
                email: "same@example.com",
                accountID: "account-1"
            ),
            CodexQuotaAccountIdentity(
                key: "same@example.com-team",
                email: "same@example.com",
                accountID: "account-2"
            ),
        ]
        let quotas = [
            "same@example.com": quota,
            "same@example.com-pro": quota,
            "same@example.com-team": quota,
        ]

        let duplicate = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: quotas,
            legacy: legacy,
            current: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
            ]
        )
        XCTAssertEqual(Set(duplicate.keys), Set(["same@example.com-pro", "same@example.com-team"]))

        let distinct = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: quotas,
            legacy: legacy,
            current: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com",
                    email: "same@example.com",
                    accountID: "account-3"
                ),
            ]
        )
        XCTAssertEqual(Set(distinct.keys), Set(quotas.keys))

        let stale = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: quotas,
            legacy: legacy,
            current: []
        )
        XCTAssertEqual(Set(stale.keys), Set(["same@example.com-pro", "same@example.com-team"]))
    }

    func testLegacyCodexAccountsUseDistinctFilenameKeysForSameEmail() {
        let plus = DirectAuthFile(
            id: "plus",
            provider: .codex,
            email: "same@example.com",
            login: nil,
            expired: nil,
            accountType: "plus",
            filePath: "/tmp/codex-same@example.com-plus.json",
            source: .cliProxyApi,
            filename: "codex-same@example.com-plus.json"
        )
        let team = DirectAuthFile(
            id: "team",
            provider: .codex,
            email: "same@example.com",
            login: nil,
            expired: nil,
            accountType: "team",
            filePath: "/tmp/codex-same@example.com-team.json",
            source: .cliProxyApi,
            filename: "codex-same@example.com-team.json"
        )

        let accounts = [plus, team].map(MonitorAccount.makeLegacy)

        let expectedKeys = Set(["same@example.com-plus", "same@example.com-team"])
        XCTAssertEqual(Set(accounts.map(\.accountKey)), expectedKeys)
        XCTAssertEqual(Set(accounts.map(\.deduplicationKey)).count, 2)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    func testStableAccountIDDoesNotDependOnSource() {
        let native = MonitorAccount.make(
            provider: .codex,
            accountKey: "User@Example.com",
            source: .nativeCredential
        )
        let legacy = MonitorAccount.make(
            provider: .codex,
            accountKey: "user@example.com",
            source: .legacyCLIProxy
        )

        XCTAssertEqual(native.id, legacy.id)
        XCTAssertEqual(native.deduplicationKey, legacy.deduplicationKey)
    }

    func testDiscoveryPrefersQuotioThenNativeThenLegacy() {
        let legacy = MonitorAccount.make(provider: .codex, accountKey: "same@example.com", source: .legacyCLIProxy)
        let native = MonitorAccount.make(provider: .codex, accountKey: "same@example.com", source: .nativeCredential)
        let owned = MonitorAccount.make(provider: .codex, accountKey: "same@example.com", source: .quotioKeychain, canDelete: true)

        let selected = MonitorAccountDiscovery.selectPreferred([legacy, native, owned])

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.source, .quotioKeychain)
        XCTAssertEqual(selected.first?.canDelete, true)
    }

    func testSnapshotRoundTripUsesIsolatedTemporaryDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("snapshots-v1.json")
        let store = MonitorSnapshotStore(url: url)
        let quota = ProviderQuotaData(
            models: [ModelQuota(name: "test", percentage: 42, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: 1234)
        )

        await store.store([.codex: ["account": quota]])
        let loaded = await store.load()

        XCTAssertEqual(loaded[.codex]?["account"]?.models.first?.percentage, 42)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLegacyModelQuotaDecodesWithoutMetricPresentation() throws {
        let data = Data(#"{"name":"legacy","percentage":42,"resetTime":"","used":3,"limit":10}"#.utf8)

        let model = try JSONDecoder().decode(ModelQuota.self, from: data)

        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.percentage, 42)
        XCTAssertEqual(model.used, 3)
        XCTAssertEqual(model.limit, 10)
    }

    func testMetricPresentationsRoundTrip() throws {
        let values: [QuotaMetricPresentation] = [
            .progress(used: 1.25, limit: 10.5, unit: .usd),
            .amount(value: 4.75, unit: .credits, semantics: .balance),
            .status(text: "Enabled"),
        ]

        for value in values {
            let decoded = try JSONDecoder().decode(
                QuotaMetricPresentation.self,
                from: JSONEncoder().encode(value)
            )
            XCTAssertEqual(decoded, value)
        }
    }

    func testZAIQuotaMappingClassifiesWindowsAndSearches() {
        let data = GLMQuotaData(limits: [
            GLMLimit(type: "TOKENS_LIMIT", unit: 3, number: 5, usage: 100, currentValue: 20, remaining: 80, percentage: 20, usageDetails: nil, nextResetTime: nil),
            GLMLimit(type: "TOKENS_LIMIT", unit: 4, number: 7, usage: 100, currentValue: 60, remaining: 40, percentage: 60, usageDetails: nil, nextResetTime: nil),
            GLMLimit(type: "TIME_LIMIT", unit: 4, number: 1, usage: 1000, currentValue: 125, remaining: 875, percentage: 12.5, usageDetails: nil, nextResetTime: nil),
        ])

        let quota = GLMQuotaFetcher.mapQuotaData(data, planName: "GLM Coding Pro")

        XCTAssertEqual(quota.planType, "GLM Coding Pro")
        XCTAssertEqual(quota.models.map(\.name), ["zai-session", "zai-weekly", "zai-web-searches"])
        XCTAssertEqual(quota.models[0].percentage, 80)
        XCTAssertEqual(quota.models[1].percentage, 40)
        XCTAssertEqual(quota.models[2].presentation, .progress(used: 125, limit: 1000, unit: .searches))
        XCTAssertEqual(GLMQuotaFetcher.apiRoot(from: "https://bigmodel.cn/api/paas/v4"), "https://bigmodel.cn")
    }

    func testZAIQuotaResponseDecodesOptionalLiveFields() throws {
        let payload = Data(#"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":25},{"type":"TIME_LIMIT","usage":1000,"currentValue":0}]},"success":true}"#.utf8)

        let response = try JSONDecoder().decode(GLMQuotaResponse.self, from: payload)
        let quota = GLMQuotaFetcher.mapQuotaData(try XCTUnwrap(response.data), planName: nil)

        XCTAssertEqual(quota.models.map(\.name), ["zai-weekly", "zai-web-searches"])
        XCTAssertEqual(quota.models[1].presentation, .progress(used: 0, limit: 1000, unit: .searches))
    }

    func testDevinMappingPreservesRemainingConventionAndWeeklyFallback() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "userStatus": [
                "planStatus": [
                    "planInfo": ["planName": "Max", "hideDailyQuota": true],
                    "dailyQuotaRemainingPercent": 30,
                    "overageBalanceMicros": "0",
                ],
            ],
        ])

        let quota = try XCTUnwrap(DevinQuotaMapper.map(data))

        XCTAssertEqual(quota.models.first(where: { $0.name == "devin-weekly" })?.percentage, 30)
        XCTAssertEqual(
            quota.models.first(where: { $0.name == "devin-extra-balance" })?.presentation,
            .amount(value: 0, unit: .usd, semantics: .balance)
        )
        XCTAssertEqual(quota.planType, "Max")
    }

    func testDevinTOMLParsesNativeCredentialAndHTTPSOnlyServer() {
        let native = DevinQuotaFetcher.parseCredentialsTOML("""
        windsurf_api_key = "native-token"
        api_server_url = "https://server.codeium.test/"
        """)
        let insecure = DevinQuotaFetcher.parseCredentialsTOML("""
        windsurf_api_key = "native-token"
        api_server_url = "http://server.codeium.test"
        """)

        XCTAssertEqual(native, DevinCredential(apiKey: "native-token", apiServerURL: "https://server.codeium.test"))
        XCTAssertNil(insecure?.apiServerURL)
    }

    func testDevinReadsSQLiteAppCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("state.vscdb").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{\"apiKey\":\"app-token\"}')", nil, nil, nil), SQLITE_OK)

        XCTAssertEqual(
            DevinQuotaFetcher.loadAppCredential(path: path),
            DevinCredential(apiKey: "app-token", apiServerURL: nil)
        )
    }

    func testGrokParsesMultipleAccountsAndSkipsInvalidEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "account-a::client-a": ["key": "token-a", "refresh_token": "refresh-a"],
            "account-b::client-b": ["key": "token-b"],
            "invalid": ["refresh_token": "refresh-only"],
        ])
        try data.write(to: url)

        let candidates = GrokQuotaFetcher.loadCandidates(path: url.path)

        XCTAssertEqual(candidates.map(\.entryKey), ["account-a::client-a", "account-b::client-b"])
        XCTAssertEqual(candidates.map(\.clientID), ["client-a", "client-b"])
    }

    func testGrokMapsOnlyWeeklyPeriodAndStatusCap() throws {
        let weekly = try JSONSerialization.data(withJSONObject: [
            "config": [
                "creditUsagePercent": 25,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2030-01-08T00:00:00Z"],
                "onDemandCap": ["val": 2500],
            ],
        ])
        let legacy = try JSONSerialization.data(withJSONObject: [
            "config": [
                "creditUsagePercent": 25,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY", "end": "2030-02-01T00:00:00Z"],
            ],
        ])

        let weeklyQuota = try XCTUnwrap(GrokQuotaMapper.mapBilling(weekly, plan: "SuperGrok"))
        let legacyQuota = try XCTUnwrap(GrokQuotaMapper.mapBilling(legacy, plan: nil))

        XCTAssertEqual(weeklyQuota.models.first(where: { $0.name == "grok-weekly" })?.percentage, 75)
        XCTAssertEqual(
            weeklyQuota.models.first(where: { $0.name == "grok-extra-usage" })?.presentation,
            .status(text: String(format: "grok.status.cap".localizedStatic(), "2500"))
        )
        XCTAssertNil(legacyQuota.models.first(where: { $0.name == "grok-weekly" }))
    }

    func testGrokAtomicRotationPreservesSiblingAndUnknownFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auth.json")
        let original: [String: Any] = [
            "target": ["key": "old", "refresh_token": "old-refresh", "unknown": "keep"],
            "sibling": ["key": "sibling-token", "custom": 42],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        try GrokQuotaFetcher.persistRotatedCredential(
            path: url.path,
            entryKey: "target",
            accessToken: "new",
            refreshToken: "new-refresh",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let updated = try XCTUnwrap(MonitorIdentity.json(at: url.path))
        XCTAssertEqual((updated["target"] as? [String: Any])?["unknown"] as? String, "keep")
        XCTAssertEqual((updated["sibling"] as? [String: Any])?["key"] as? String, "sibling-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOpenRouterPartialSuccessKeepsDecimalMetrics() throws {
        let credits = OpenRouterEndpointResult(
            data: try JSONSerialization.data(withJSONObject: ["data": ["total_credits": 100.25, "total_usage": 40.10]]),
            statusCode: 200
        )
        let failedKey = OpenRouterEndpointResult(data: nil, statusCode: 503)

        let quota = try XCTUnwrap(OpenRouterQuotaMapper.map(credits: credits, key: failedKey))

        XCTAssertEqual(quota.models.first(where: { $0.name == "openrouter-credits" })?.presentation, .progress(used: 40.10, limit: 100.25, unit: .usd))
        XCTAssertEqual(quota.models.first(where: { $0.name == "openrouter-balance" })?.presentation, .amount(value: 60.15, unit: .usd, semantics: .balance))
    }

    func testOpenRouterZeroBalanceAndAuthenticationFailure() throws {
        let zeroCredits = OpenRouterEndpointResult(
            data: try JSONSerialization.data(withJSONObject: ["data": ["total_credits": 0, "total_usage": 0]]),
            statusCode: 200
        )
        let failedKey = OpenRouterEndpointResult(data: nil, statusCode: 500)
        let zero = try XCTUnwrap(OpenRouterQuotaMapper.map(credits: zeroCredits, key: failedKey))
        XCTAssertEqual(zero.models.first?.presentation, .amount(value: 0, unit: .usd, semantics: .balance))

        let forbidden = try XCTUnwrap(OpenRouterQuotaMapper.map(
            credits: OpenRouterEndpointResult(data: Data(), statusCode: 401),
            key: OpenRouterEndpointResult(data: Data(), statusCode: 403)
        ))
        XCTAssertTrue(forbidden.isForbidden)
    }

    func testMonitorCredentialVaultAddsRotatesAndDeletesOpenRouterKey() async throws {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        let vault = MonitorCredentialVault(metadata: MonitorMetadataStore(url: metadataURL))
        let account = MonitorAccount.make(
            provider: .openRouter,
            accountKey: "Test " + UUID().uuidString,
            source: .quotioKeychain,
            canDelete: true
        )
        let first = MonitorOAuthCredential(accessToken: "first", refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:])
        let second = MonitorOAuthCredential(accessToken: "second", refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:])

        try await vault.save(first, metadata: account)
        let loadedFirst = await vault.credential(for: account.id)
        XCTAssertEqual(loadedFirst?.accessToken, "first")
        try await vault.save(second, metadata: account)
        let loadedSecond = await vault.credential(for: account.id)
        XCTAssertEqual(loadedSecond?.accessToken, "second")
        await vault.delete(accountID: account.id)
        let deleted = await vault.credential(for: account.id)
        XCTAssertNil(deleted)
    }

    func testMetadataRoundTripStoresOwnedAccountAndDisabledState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts-v1.json")
        let store = MonitorMetadataStore(url: url)
        let account = MonitorAccount.make(
            provider: .gemini,
            accountKey: "test@example.com",
            source: .quotioKeychain,
            canDelete: true
        )

        try await store.saveAccount(account)
        try await store.setDisabled(true, accountID: account.id)

        let accounts = await store.accounts()
        let disabled = await store.disabledAccountIDs()
        XCTAssertEqual(accounts, [account])
        XCTAssertEqual(disabled, Set([account.id]))
    }

    func testQuotaDerivedAccountPreservesDisabledState() {
        let account = MonitorAccount.make(
            provider: .cursor,
            accountKey: "cursor@example.com",
            source: .localIDE
        )

        let derived = MonitorRefreshCoordinator.makeQuotaDerivedAccount(
            provider: .cursor,
            accountKey: account.accountKey,
            source: .localIDE,
            disabledIDs: [account.id]
        )

        XCTAssertTrue(derived.isDisabled)
    }

    func testCoordinatorRetainsLastGoodQuotaOnTransientFailure() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = MonitorRefreshCoordinator(
            snapshots: MonitorSnapshotStore(url: directory.appendingPathComponent("snapshot.json"))
        )
        let previous = ProviderQuotaData(
            models: [ModelQuota(name: "test", percentage: 75, resetTime: "")],
            lastUpdated: Date()
        )

        let result = await coordinator.refresh(
            provider: .codex,
            force: true,
            previous: ["account": previous],
            operation: { [:] }
        )

        XCTAssertEqual(result["account"]?.models.first?.percentage, 75)
        let issues = await coordinator.currentIssues()
        XCTAssertNotNil(issues[.codex])
    }

    func testCoordinatorRemovesStaleQuotaWhenCredentialsAreMissing() async {
        let coordinator = MonitorRefreshCoordinator()
        let previous = ["account": ProviderQuotaData(models: [], lastUpdated: Date())]

        let result = await coordinator.refresh(
            provider: .codex,
            force: true,
            previous: previous,
            credentialAvailability: .missing,
            operation: { [:] }
        )

        XCTAssertTrue(result.isEmpty)
        let issues = await coordinator.currentIssues()
        XCTAssertNil(issues[.codex])
    }

    func testMonitorStatusDoesNotBorrowSiblingTimestamp() {
        let account = MonitorAccount.make(
            provider: .claude,
            accountKey: "failed@example.com",
            source: .nativeCredential
        )
        let sibling = ProviderQuotaData(models: [], lastUpdated: Date())

        let updated = QuotaViewModel.monitorLastUpdated(
            for: account,
            providerQuotas: [.claude: ["successful@example.com": sibling]]
        )

        XCTAssertNil(updated)
    }

    func testKiroFallbackAccountKeysDoNotCollide() {
        let first = MonitorOAuthCoordinator.kiroAccountKey(identity: nil, clientID: "client-1")
        let second = MonitorOAuthCoordinator.kiroAccountKey(identity: nil, clientID: "client-2")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            MonitorOAuthCoordinator.kiroAccountKey(identity: "builder@example.com", clientID: "client-1"),
            "builder@example.com"
        )
    }

    func testNumericCamelCaseKiroExpiryIsParsed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("kiro.json")
        let timestamp = 1_900_000_000.0
        let data = try JSONSerialization.data(withJSONObject: [
            "accessToken": "test-access-token",
            "expiresAt": timestamp,
        ])
        try data.write(to: url)
        let file = DirectAuthFile(
            id: url.path,
            provider: .kiro,
            email: nil,
            login: nil,
            expired: nil,
            accountType: nil,
            filePath: url.path,
            source: .nativeCredential,
            filename: url.lastPathComponent
        )

        let token = await DirectAuthFileService().readAuthToken(from: file)

        XCTAssertEqual(token?.expiresAt, ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp)))
    }

    func testCoordinatorCoalescesConcurrentRefreshForProvider() async {
        let coordinator = MonitorRefreshCoordinator()
        let counter = Counter()
        async let first = coordinator.refresh(provider: .codex, force: true, previous: [:]) {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return ["account": ProviderQuotaData(models: [], lastUpdated: Date())]
        }
        async let second = coordinator.refresh(provider: .codex, force: true, previous: [:]) {
            await counter.increment()
            return ["other": ProviderQuotaData(models: [], lastUpdated: Date())]
        }

        _ = await (first, second)
        let coalescedCount = await counter.value
        XCTAssertEqual(coalescedCount, 1)
    }

    func testManualRefreshBypassesProviderBackoff() async {
        let coordinator = MonitorRefreshCoordinator()
        let counter = Counter()
        let previous = ["account": ProviderQuotaData(models: [], lastUpdated: Date())]
        _ = await coordinator.refresh(provider: .codex, force: true, previous: previous) { [:] }
        _ = await coordinator.refresh(provider: .codex, force: false, previous: previous) {
            await counter.increment()
            return [:]
        }
        let backedOffCount = await counter.value
        XCTAssertEqual(backedOffCount, 0)

        _ = await coordinator.refresh(provider: .codex, force: true, previous: previous) {
            await counter.increment()
            return previous
        }
        let forcedCount = await counter.value
        XCTAssertEqual(forcedCount, 1)
    }

    func testAtomicWriterRefusesSymbolicLinkDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("link.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SecureAtomicFileWriter.write(Data("new".utf8), to: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    func testLoopbackCallbackReturnsCodeAndState() async throws {
        let server = MonitorOAuthCallbackServer()
        let port = try await server.start()
        async let callback = server.waitForCallback(timeout: .seconds(2))

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?code=test-code&state=test-state")!
        _ = try await URLSession.shared.data(from: url)
        let result = try await callback
        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems

        XCTAssertEqual(items?.first(where: { $0.name == "code" })?.value, "test-code")
        XCTAssertEqual(items?.first(where: { $0.name == "state" })?.value, "test-state")
    }

    func testLoopbackCallbackTimesOut() async throws {
        let server = MonitorOAuthCallbackServer()
        _ = try await server.start()
        do {
            _ = try await server.waitForCallback(timeout: .milliseconds(30))
            XCTFail("Expected timeout")
        } catch MonitorOAuthError.expired {
            // Expected.
        }
    }

    func testOAuthCallbackRejectsMismatchedState() throws {
        let callback = URL(string: "http://localhost/callback?code=test&state=unexpected")!
        XCTAssertThrowsError(
            try MonitorOAuthCoordinator.authorizationCode(from: callback, expectedState: "expected")
        ) { error in
            guard case MonitorOAuthError.stateMismatch = error else {
                return XCTFail("Expected state mismatch")
            }
        }
    }
}
