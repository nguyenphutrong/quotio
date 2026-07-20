import XCTest
@testable import Quotio

final class MonitorRuntimeTests: XCTestCase {
    func testMonitorProvidersDoNotRequireInstalledCLI() {
        let providers: Set<AIProvider> = [.codex, .claude, .gemini]

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
