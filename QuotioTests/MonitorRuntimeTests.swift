import CryptoKit
import LocalAuthentication
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import Security
import XCTest
@testable import Quotio

final class MonitorRuntimeTests: XCTestCase {
    func testVaultMigrationOnlyFallsBackWhenEnvelopeIsAbsent() {
        XCTAssertTrue(YubiKeySecretVault.shouldMigrateLegacy(.absent))
        XCTAssertFalse(YubiKeySecretVault.shouldMigrateLegacy(.unreadable))
        XCTAssertFalse(YubiKeySecretVault.shouldMigrateLegacy(.success(Data("current".utf8))))
    }

    func testMissingEnvelopeIsDistinguishedFromUnreadableEnvelope() {
        let service = "tests"
        let account = "unreadable-envelope-\(UUID().uuidString)"
        XCTAssertEqual(
            YubiKeySecretVault.readResult(service: service, account: "missing-\(account)"),
            .absent
        )
        let digest = SHA256.hash(data: Data("\(service)\u{0}\(account)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio", isDirectory: true)
            .appendingPathComponent("YubiKeyVault", isDirectory: true)
        let envelopeURL = directory.appendingPathComponent(digest).appendingPathExtension("qsv")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("malformed envelope".utf8).write(to: envelopeURL)
        defer { try? FileManager.default.removeItem(at: envelopeURL) }
        XCTAssertEqual(
            YubiKeySecretVault.readResult(service: service, account: account),
            .unreadable
        )
    }

    // MARK: - PIV provisioning preflight
    //
    // Fixtures are the literal output of `ykman piv info`, rendered through
    // ykman's own pretty-printer so the shape cannot drift from the tool.

    private static let occupiedSlotReport = """
    PIV version:              5.7.1
    PIN tries remaining:      3/3
    PUK tries remaining:      3/3
    Management key algorithm: AES192
    Management key is stored on the YubiKey, protected by PIN.
    CHUID: 3019d4e7...
    CCC:   No data available
    Slot 9D (KEY_MANAGEMENT):
      Private key type: RSA2048
      Subject DN:       CN=Quotio Secret Vault
      Not after:        2036-01-01 00:00:00
    """

    private static let emptySlotReport = """
    PIV version:              5.7.1
    PIN tries remaining:      3/3
    Management key algorithm: TDES
    WARNING: Using default Management key!
    CHUID: No data available
    CCC:   No data available
    """

    private static let legacyFirmwareReport = """
    PIV version:              4.3.7
    PIN tries remaining:      15 or more
    Management key algorithm: TDES
    CHUID: No data available
    CCC:   No data available
    """

    func testPreflightReportsOccupiedSlotAsDestructive() {
        let preflight = YubiKeySecretVault.parsePreflight(Self.occupiedSlotReport)
        XCTAssertEqual(preflight.slot9d, .occupied)
        XCTAssertTrue(preflight.destroysExistingKey)
        XCTAssertEqual(preflight.pinTriesRemaining, "3/3")
    }

    func testPreflightReportsEmptySlotOnlyWhenFirmwareCanProveIt() {
        let preflight = YubiKeySecretVault.parsePreflight(Self.emptySlotReport)
        XCTAssertEqual(preflight.slot9d, .empty)
        XCTAssertFalse(preflight.destroysExistingKey)
    }

    /// Key metadata arrived in PIV 5.3. Below that a bare private key is
    /// invisible to `piv info`, so "not listed" must never be read as "empty".
    func testPreflightTreatsUnprovableSlotAsUnknownAndDestructive() {
        let legacy = YubiKeySecretVault.parsePreflight(Self.legacyFirmwareReport)
        XCTAssertEqual(legacy.slot9d, .unknown)
        XCTAssertTrue(legacy.destroysExistingKey)
        XCTAssertEqual(legacy.pinTriesRemaining, "15 or more")

        let versionless = YubiKeySecretVault.parsePreflight("CHUID: No data available")
        XCTAssertEqual(versionless.slot9d, .unknown)
        XCTAssertTrue(versionless.destroysExistingKey)
        XCTAssertNil(versionless.pinTriesRemaining)
    }

    /// A populated slot that is not 9d says nothing about 9d.
    func testPreflightIgnoresOtherOccupiedSlots() {
        let report = Self.emptySlotReport + """

        Slot 9A (AUTHENTICATION):
          Private key type: ECCP256
        """
        XCTAssertEqual(YubiKeySecretVault.parsePreflight(report).slot9d, .empty)
    }

    /// `provision` only feeds a management-key line when ykman will ask for one,
    /// and ykman asks only while the key is unprotected. Misreading this shifts
    /// the PIN onto the wrong prompt and burns a PIN attempt.
    func testPreflightDetectsProtectedManagementKey() {
        XCTAssertTrue(YubiKeySecretVault.parsePreflight(Self.occupiedSlotReport).managementKeyProtected)

        let derived = YubiKeySecretVault.parsePreflight("""
        PIV version:              5.7.1
        Management key is derived from PIN.
        """)
        XCTAssertTrue(derived.managementKeyProtected)

        let unprotected = YubiKeySecretVault.parsePreflight(Self.emptySlotReport)
        XCTAssertFalse(unprotected.managementKeyProtected)
        XCTAssertTrue(unprotected.usesDefaultManagementKey)
    }

    /// The instance ID is the value macOS actually reports, observed on a
    /// YubiKey 5C NFC (5.4.3). Matching only the bare driver ID hid every PIV
    /// identity, so Settings stayed on "not configured" after a successful setup.
    func testPIVTokenMatchesInstanceIDNotJustDriverID() {
        XCTAssertTrue(YubiKeySecretVault.isPIVToken("com.apple.pivtoken:48B9336CB599456CAC0A442D8EE59713"))
        XCTAssertTrue(YubiKeySecretVault.isPIVToken("com.apple.pivtoken"))
        XCTAssertTrue(YubiKeySecretVault.isPIVToken("com.apple.CryptoTokenKit.pivtoken"))
    }

    func testPIVTokenRejectsSoftwareAndSecureEnclaveKeys() {
        XCTAssertFalse(YubiKeySecretVault.isPIVToken(nil))
        XCTAssertFalse(YubiKeySecretVault.isPIVToken(""))
        XCTAssertFalse(YubiKeySecretVault.isPIVToken("com.apple.setoken"))
        // Prefix-only matching would wrongly accept an unrelated driver.
        XCTAssertFalse(YubiKeySecretVault.isPIVToken("com.apple.pivtokenizer:1234"))
    }

    func testPIVIdentityQueryOnlyReturnsExternalTokenMetadataAndReferences() {
        let query = YubiKeySecretVault.availableIdentityQuery()

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassIdentity as String)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, kSecAttrAccessGroupToken as String)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnRef as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertTrue(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        )
    }

    /// The rollback this prevents: with the vault enabled and the key absent or
    /// the PIN prompt dismissed, proxy initialization reads nil, mints a fresh
    /// UUID and saves it — destroying the envelope holding the real management
    /// key. Absent must still be writable, or first-time storage would break.
    func testVaultWriteRefusesToOverwriteUnreadableEnvelope() {
        XCTAssertFalse(KeychainHelper.allowsVaultOverwrite(.unreadable))
        XCTAssertTrue(KeychainHelper.allowsVaultOverwrite(.absent))
        XCTAssertTrue(KeychainHelper.allowsVaultOverwrite(.success(Data("rotated".utf8))))
    }

    func testExternalCredentialOperationsDoNotAllowAuthenticationUI() {
        let readQuery = ExternalKeychainCredentialReader.readQuery(
            service: "fixture.external",
            account: "fixture-account"
        )
        let updateQuery = ExternalKeychainCredentialReader.updateQuery(
            service: "fixture.external",
            account: "fixture-account"
        )

        XCTAssertEqual(readQuery[kSecAttrService as String] as? String, "fixture.external")
        XCTAssertEqual(readQuery[kSecAttrAccount as String] as? String, "fixture-account")
        XCTAssertTrue(
            (readQuery[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        )
        XCTAssertEqual(updateQuery[kSecAttrService as String] as? String, "fixture.external")
        XCTAssertEqual(updateQuery[kSecAttrAccount as String] as? String, "fixture-account")
        XCTAssertTrue(
            (updateQuery[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        )
    }

    /// External reads must never reach securityd with user interaction enabled: the legacy
    /// login keychain ignores `LAContext.interactionNotAllowed` and would otherwise show the
    /// "wants to access key" password dialog. The flag is process-global, so it must also be
    /// restored once the call returns or every later keychain operation would fail silently.
    func testExternalCredentialReadRestoresProcessInteractionFlag() async {
        var before: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)

        let reader = ExternalKeychainCredentialReader()
        let missingCredential = await reader.read(
            service: "fixture.external.missing.\(UUID().uuidString)",
            account: nil
        )
        let didReplaceMissingCredential = await reader.compareAndSwap(
            service: "fixture.external.missing.\(UUID().uuidString)",
            account: "fixture-account",
            expectedData: Data(),
            newData: Data("unused".utf8)
        )
        XCTAssertNil(missingCredential)
        XCTAssertFalse(didReplaceMissingCredential)

        var after: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(after.boolValue, before.boolValue)
    }

    func testMonitorProvidersDoNotRequireInstalledCLI() {
        let providers: Set<AIProvider> = [.codex, .claude, .factoryDroid, .devin, .grok, .openRouter, .amp]

        let filtered = StatusBarMenuBuilder.filterProviders(
            providers,
            isMonitorMode: true,
            isCLIInstalled: { _ in false }
        )

        XCTAssertEqual(Set(filtered), providers)
    }

    func testMonitorOnlyProvidersDoNotOfferLocalProxySetup() {
        for provider in [AIProvider.factoryDroid, .devin, .grok, .openRouter, .amp, .warp] {
            XCTAssertFalse(provider.supportsLocalProxySetup)
        }
        XCTAssertTrue(AIProvider.claude.supportsLocalProxySetup)
    }

    func testStatusBarIncludesEnabledMonitorAccountsWithoutQuota() {
        let enabled = MonitorAccount.make(
            provider: .claude,
            accountKey: "enabled@example.com",
            source: .nativeCredential
        )
        var disabled = MonitorAccount.make(
            provider: .codex,
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

    func testCopilotCanonicalKeyPrefersLoginOverEmail() {
        let direct = DirectAuthFile(
            id: "copilot",
            provider: .copilot,
            email: "person@example.com",
            login: "octocat",
            expired: nil,
            accountType: nil,
            filePath: "/tmp/github-copilot-octocat.json",
            source: .cliProxyApi,
            filename: "github-copilot-octocat.json"
        )
        let proxy = AuthFile(
            id: "copilot",
            name: "github-copilot-octocat.json",
            provider: "github-copilot",
            label: nil,
            status: "ready",
            statusMessage: nil,
            disabled: false,
            unavailable: false,
            runtimeOnly: false,
            source: nil,
            path: nil,
            email: "person@example.com",
            accountType: nil,
            account: "octocat",
            authIndex: nil,
            createdAt: nil,
            updatedAt: nil,
            lastRefresh: nil
        )

        XCTAssertEqual(direct.menuBarAccountKey, "octocat")
        XCTAssertEqual(MonitorAccount.makeLegacy(direct).accountKey, "octocat")
        XCTAssertEqual(proxy.quotaLookupKey, "octocat")
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

    func testCountMetricUnitsUseEnglishSingularAndPluralForms() {
        let previousLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("en", forKey: "appLanguage")
        defer { UserDefaults.standard.set(previousLanguage, forKey: "appLanguage") }

        XCTAssertEqual(QuotaMetricUnit.credits.format(1), "1 credit")
        XCTAssertEqual(QuotaMetricUnit.credits.format(2), "2 credits")
        XCTAssertEqual(QuotaMetricUnit.requests.format(1), "1 request")
        XCTAssertEqual(QuotaMetricUnit.requests.format(2), "2 requests")
        XCTAssertEqual(QuotaMetricUnit.searches.format(1), "1 search")
        XCTAssertEqual(QuotaMetricUnit.searches.format(2), "2 searches")
    }

    @MainActor
    func testGLMEditorPreservesExistingProviderConfiguration() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let firstKeyID = UUID()
        let secondKey = CustomAPIKeyEntry(apiKey: "second-key", proxyURL: "https://second.proxy")
        let existing = CustomProvider(
            name: "Existing Z.ai",
            type: .glmCompatibility,
            baseURL: GLMEndpoint.bigmodel.baseURL,
            prefix: "existing-prefix",
            apiKeys: [
                CustomAPIKeyEntry(id: firstKeyID, apiKey: "first-key", proxyURL: "https://first.proxy"),
                secondKey,
            ],
            limitToSelectedModels: false,
            isEnabled: false,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let updated = GLMProviderEditor.updatedProvider(
            existing,
            apiKey: "rotated-key",
            endpoint: .zai,
            now: updatedAt
        )

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.name, "Existing Z.ai")
        XCTAssertEqual(updated.baseURL, GLMEndpoint.zai.baseURL)
        XCTAssertEqual(updated.prefix, "existing-prefix")
        XCTAssertEqual(updated.apiKeys.count, 2)
        XCTAssertEqual(updated.apiKeys[0].id, firstKeyID)
        XCTAssertEqual(updated.apiKeys[0].apiKey, "rotated-key")
        XCTAssertEqual(updated.apiKeys[0].proxyURL, "https://first.proxy")
        XCTAssertEqual(updated.apiKeys[1], secondKey)
        XCTAssertFalse(updated.limitToSelectedModels)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)
    }

    func testOpenRouterPlanLabelsUseLocalization() {
        let previousLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("vi", forKey: "appLanguage")
        defer { UserDefaults.standard.set(previousLanguage, forKey: "appLanguage") }

        XCTAssertEqual(ProviderQuotaData(planType: "openrouter-free").planDisplayName, "Gói miễn phí")
    }

    @MainActor
    func testZAIEndpointLabelUsesLocalization() {
        let previousLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("vi", forKey: "appLanguage")
        defer { UserDefaults.standard.set(previousLanguage, forKey: "appLanguage") }

        XCTAssertEqual(GLMEndpoint.zai.displayName, "Z.ai Toàn cầu")
    }

    func testMonitorCredentialVaultAddsRotatesAndDeletesAPIKeys() async throws {
        // The test host shares the app's defaults, so whoever has enabled the
        // vault runs this against the vault: every read then needs a physical
        // PIN entry (the slot is `--pin-policy always`), and the run stalls,
        // prompts once per read, and fails. Skip rather than force the Keychain
        // path -- clearing the fingerprint would switch off a real security
        // setting, and a crash mid-test would leave it off.
        try XCTSkipIf(
            YubiKeySecretVault.isEnabled,
            "Requires the Keychain backend; disable the YubiKey vault in Settings to run."
        )

        for provider in [AIProvider.factoryDroid, .openRouter, .amp] {
            let metadataURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("accounts.json")
            let vault = CredentialVaultService(
                dataStore: KeychainCredentialDataStore(
                    service: "quotio-tests-monitor-auth-\(UUID().uuidString)",
                    canMigrateLegacy: false
                ),
                metadataRepository: FileAccountMetadataRepository(url: metadataURL)
            )
            let account = MonitorAccount.make(
                provider: provider,
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
    }

    func testAmpNativeAndNamedAccountDoNotCollide() {
        let native = AmpQuotaFetcher.localAccount(provider: .amp)
        let named = MonitorAccount.make(
            provider: .amp,
            accountKey: "Amp",
            source: .quotioKeychain,
            canDelete: true
        )

        XCTAssertEqual(MonitorAccountDiscovery.selectPreferred([native, named]).count, 2)
        XCTAssertEqual(native.displayName, "Amp")
        XCTAssertNotEqual(native.accountKey, named.accountKey)
    }

    func testMetadataRoundTripStoresOwnedAccountAndDisabledState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts-v1.json")
        let store = MonitorMetadataStore(url: url)
        let account = MonitorAccount.make(
            provider: .codex,
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

    func testMetadataLoadDropsLegacyGeminiAccountWithoutDroppingOtherProviders() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codex = MonitorAccount.make(
            provider: .codex,
            accountKey: "codex@example.com",
            source: .quotioKeychain
        )
        let codexObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(codex)) as? [String: Any]
        )
        var geminiObject = codexObject
        geminiObject["id"] = "legacy-gemini"
        geminiObject["provider"] = "gemini-cli"
        let payload: [String: Any] = [
            "accounts": [codexObject, geminiObject],
            "disabledAccountIDs": ["legacy-gemini"],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)

        let store = MonitorMetadataStore(url: url)
        let accounts = await store.accounts()
        let disabled = await store.disabledAccountIDs()

        XCTAssertEqual(accounts, [codex])
        XCTAssertTrue(disabled.isEmpty)

        let reloadedStore = MonitorMetadataStore(url: url)
        let reloadedAccounts = await reloadedStore.accounts()
        let reloadedDisabled = await reloadedStore.disabledAccountIDs()

        XCTAssertEqual(reloadedAccounts, [codex])
        XCTAssertTrue(reloadedDisabled.isEmpty)
    }

    @MainActor
    func testAutoDetectedAccountRowsAllowDeleteOnlyForIDEProviders() {
        // Providers screen rows for scanned IDE accounts must offer delete (issue #213).
        for provider in [AIProvider.cursor, .trae] {
            let row = AccountRowData.from(provider: provider, accountKey: "user@example.com")
            XCTAssertTrue(row.canDelete, "\(provider.rawValue) row should be deletable")
            XCTAssertEqual(row.source, .autoDetected)
        }
        for provider in [AIProvider.devin, .grok] {
            let row = AccountRowData.from(provider: provider, accountKey: "user@example.com")
            XCTAssertFalse(row.canDelete, "\(provider.rawValue) row should not be deletable")
        }
    }

    func testKiroFallbackAccountKeysDoNotCollide() {
        let first = MonitorOAuthAuthorizer.kiroAccountKey(identity: nil, clientID: "client-1")
        let second = MonitorOAuthAuthorizer.kiroAccountKey(identity: nil, clientID: "client-2")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            MonitorOAuthAuthorizer.kiroAccountKey(identity: "builder@example.com", clientID: "client-1"),
            "builder@example.com"
        )
    }

    func testAtomicWriterRefusesSymbolicLinkDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("link.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try QuotioInfrastructure.SecureAtomicFileWriter.write(Data("new".utf8), to: link)
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    func testOAuthCallbackRejectsMismatchedState() throws {
        let callback = URL(string: "http://localhost/callback?code=test&state=unexpected")!
        XCTAssertThrowsError(
            try MonitorOAuthAuthorizer.authorizationCode(from: callback, expectedState: "expected")
        ) { error in
            guard case OAuthFlowFailure.stateMismatch = error else {
                return XCTFail("Expected state mismatch")
            }
        }
    }
}
