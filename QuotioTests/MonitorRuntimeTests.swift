import CryptoKit
import LocalAuthentication
import Security
import SQLite3
import XCTest
@testable import Quotio

final class MonitorRuntimeTests: XCTestCase {
    func testMonitorCredentialCASUsesActiveVaultBackend() {
        XCTAssertEqual(KeychainHelper.monitorCredentialBackend(vaultEnabled: true), .vault)
        XCTAssertEqual(KeychainHelper.monitorCredentialBackend(vaultEnabled: false), .keychain)
    }

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
    /// the PIN prompt dismissed, `CLIProxyManager.init` reads nil, mints a fresh
    /// UUID and saves it — destroying the envelope holding the real management
    /// key. Absent must still be writable, or first-time storage would break.
    func testVaultWriteRefusesToOverwriteUnreadableEnvelope() {
        XCTAssertFalse(KeychainHelper.allowsVaultOverwrite(.unreadable))
        XCTAssertTrue(KeychainHelper.allowsVaultOverwrite(.absent))
        XCTAssertTrue(KeychainHelper.allowsVaultOverwrite(.success(Data("rotated".utf8))))
    }

    /// Covers the effect through a public entry point. Honest limit: with no
    /// identity selected the vault write would fail regardless, so this pins the
    /// outcome but does not by itself prove the guard short-circuits first —
    /// `allowsVaultOverwrite` above covers the decision, and separating an
    /// unreadable envelope from a missing key needs hardware.
    @MainActor
    func testUnreadableEnvelopeSurvivesACredentialSave() {
        let defaults = UserDefaults.standard
        let fingerprintKey = "yubikeyPIVVaultFingerprint"
        let previousFingerprint = defaults.string(forKey: fingerprintKey)
        defaults.set("0000000000000000000000000000000000000000000000000000000000000000", forKey: fingerprintKey)
        defer {
            if let previousFingerprint {
                defaults.set(previousFingerprint, forKey: fingerprintKey)
            } else {
                defaults.removeObject(forKey: fingerprintKey)
            }
        }
        XCTAssertTrue(YubiKeySecretVault.isEnabled)

        // A per-run account, so the real credentials of whoever runs the suite
        // are never the thing being overwritten.
        let configId = UUID().uuidString
        let service = AppIdentity.keychainService(suffix: "remote-management")
        let account = "management-key-\(configId)"
        let digest = SHA256.hash(data: Data("\(service)\u{0}\(account)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio", isDirectory: true)
            .appendingPathComponent("YubiKeyVault", isDirectory: true)
        let envelopeURL = directory.appendingPathComponent(digest).appendingPathExtension("qsv")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = Data("sealed-credential-that-must-survive".utf8)
        try? sentinel.write(to: envelopeURL)
        defer { try? FileManager.default.removeItem(at: envelopeURL) }

        XCTAssertEqual(YubiKeySecretVault.readResult(service: service, account: account), .unreadable)
        KeychainHelper.saveManagementKey("regenerated-by-a-failed-read", for: configId)
        XCTAssertEqual(try? Data(contentsOf: envelopeURL), sentinel)
    }

    func testExternalCredentialOperationsDoNotAllowAuthenticationUI() {
        let readQuery = KeychainHelper.externalCredentialQuery(service: "fixture.external", account: "fixture-account")
        let updateQuery = KeychainHelper.externalCredentialUpdateQuery(service: "fixture.external", account: "fixture-account")

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

    func testCodexQuotaReconciliationPromotesFreshQuotaToMatchingLegacyAlias() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let quotas = [
            "same@example.com": ProviderQuotaData(models: [], lastUpdated: freshDate),
            "same@example.com-pro": ProviderQuotaData(models: [], lastUpdated: staleDate),
        ]

        let reconciled = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: quotas,
            legacy: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com-pro",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
            ],
            current: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["same@example.com-pro"])
        XCTAssertEqual(reconciled["same@example.com-pro"]?.lastUpdated, freshDate)
    }

    func testCodexQuotaReconciliationPreservesNewerLegacyQuota() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let reconciled = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: [
                "same@example.com": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "same@example.com-pro": ProviderQuotaData(models: [], lastUpdated: freshDate),
            ],
            legacy: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com-pro",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
            ],
            current: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
            ]
        )

        XCTAssertEqual(reconciled["same@example.com-pro"]?.lastUpdated, freshDate)
    }

    func testCodexQuotaReconciliationDoesNotShareAmbiguousEmailQuota() {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 1_500)
        let emailDate = Date(timeIntervalSince1970: 2_000)
        let reconciled = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: [
                "same@example.com": ProviderQuotaData(models: [], lastUpdated: emailDate),
                "same@example.com-pro": ProviderQuotaData(models: [], lastUpdated: firstDate),
                "same@example.com-team": ProviderQuotaData(models: [], lastUpdated: secondDate),
            ],
            legacy: [
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
            ],
            current: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
                CodexQuotaAccountIdentity(
                    key: "same@example.com",
                    email: "same@example.com",
                    accountID: "account-2"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["same@example.com-pro", "same@example.com-team"])
        XCTAssertEqual(reconciled["same@example.com-pro"]?.lastUpdated, firstDate)
        XCTAssertEqual(reconciled["same@example.com-team"]?.lastUpdated, secondDate)
    }

    func testCodexQuotaReconciliationAllowsDuplicateSourcesForSameAccount() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let duplicateIdentity = CodexQuotaAccountIdentity(
            key: "same@example.com",
            email: "same@example.com",
            accountID: "account-1"
        )
        let reconciled = CodexCLIQuotaFetcher.reconcileLegacyAliases(
            in: [
                "same@example.com": ProviderQuotaData(models: [], lastUpdated: freshDate),
                "same@example.com-pro": ProviderQuotaData(models: [], lastUpdated: staleDate),
            ],
            legacy: [
                CodexQuotaAccountIdentity(
                    key: "same@example.com-pro",
                    email: "same@example.com",
                    accountID: "account-1"
                ),
            ],
            current: [duplicateIdentity, duplicateIdentity]
        )

        XCTAssertEqual(Set(reconciled.keys), ["same@example.com-pro"])
        XCTAssertEqual(reconciled["same@example.com-pro"]?.lastUpdated, freshDate)
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
            lastUpdated: Date(timeIntervalSince1970: 1234),
            accountDisplayName: "factory@example.com"
        )

        await store.store([.codex: ["account": quota]])
        let loaded = await store.load()

        XCTAssertEqual(loaded[.codex]?["account"]?.models.first?.percentage, 42)
        XCTAssertEqual(loaded[.codex]?["account"]?.accountDisplayName, "factory@example.com")
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

    func testFactoryDroidDecryptsLocalCredentialFile() throws {
        let keyData = Data((0..<32).map(UInt8.init))
        let nonce = try AES.GCM.Nonce(data: Data((32..<48).map(UInt8.init)))
        let cleartext = Data(#"{"access_token":"local-token","refresh_token":"refresh","active_organization_id":"org-123"}"#.utf8)
        let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: keyData), nonce: nonce)
        let encrypted = [
            Data(nonce).base64EncodedString(),
            sealed.tag.base64EncodedString(),
            sealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":")

        let credential = FactoryDroidCredentialReader.decryptCredential(
            encrypted: encrypted,
            keyData: Data(keyData.base64EncodedString().utf8),
            sourcePath: "/tmp/auth.v2.file"
        )

        XCTAssertEqual(credential, FactoryDroidCredential(
            accessToken: "local-token",
            refreshToken: "refresh",
            activeOrganizationID: "org-123",
            sourcePath: "/tmp/auth.v2.file"
        ))
    }

    func testFactoryDroidLoadsKeyFileCredentialFromDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyData = Data(repeating: 7, count: 32)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 8, count: 16))
        let cleartext = Data(#"{"access_token":"directory-token","active_organization_id":"org-directory"}"#.utf8)
        let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: keyData), nonce: nonce)
        let encrypted = [
            Data(nonce).base64EncodedString(),
            sealed.tag.base64EncodedString(),
            sealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":")
        try Data(encrypted.utf8).write(to: directory.appendingPathComponent("auth.v2.file"))
        try Data(keyData.base64EncodedString().utf8).write(to: directory.appendingPathComponent("auth.v2.key"))

        let credential = FactoryDroidCredentialReader.load(directory: directory)

        XCTAssertEqual(credential?.accessToken, "directory-token")
        XCTAssertNil(credential?.refreshToken)
        XCTAssertEqual(credential?.accountKey, "org-directory")
        XCTAssertEqual(
            FactoryDroidQuotaFetcher.localAccount(for: try XCTUnwrap(credential)).provider,
            .factoryDroid
        )
    }

    func testFactoryDroidLoadsNewestCredentialAcrossFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileKeyData = Data(repeating: 7, count: 32)
        try Data(fileKeyData.base64EncodedString().utf8).write(to: directory.appendingPathComponent("auth.v2.key"))
        let staleNonce = try AES.GCM.Nonce(data: Data(repeating: 1, count: 16))
        let staleSealed = try AES.GCM.seal(
            Data(#"{"access_token":"stale-token","refresh_token":"stale-refresh","active_organization_id":"org-123"}"#.utf8),
            using: SymmetricKey(data: fileKeyData),
            nonce: staleNonce
        )
        let fileURL = directory.appendingPathComponent("auth.v2.file")
        try Data([
            Data(staleNonce).base64EncodedString(),
            staleSealed.tag.base64EncodedString(),
            staleSealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":").utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: fileURL.path
        )

        let keychainKeyData = Data(repeating: 9, count: 32)
        let liveNonce = try AES.GCM.Nonce(data: Data(repeating: 2, count: 16))
        let liveSealed = try AES.GCM.seal(
            Data(#"{"access_token":"live-token","refresh_token":"live-refresh","active_organization_id":"org-123"}"#.utf8),
            using: SymmetricKey(data: keychainKeyData),
            nonce: liveNonce
        )
        try Data([
            Data(liveNonce).base64EncodedString(),
            liveSealed.tag.base64EncodedString(),
            liveSealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":").utf8).write(to: directory.appendingPathComponent("auth.v2.loginkeychain"))

        let credential = FactoryDroidCredentialReader.load(
            directory: directory,
            keychainKey: Data(keychainKeyData.base64EncodedString().utf8)
        )

        XCTAssertEqual(credential?.accessToken, "live-token")
        XCTAssertEqual(credential?.refreshToken, "live-refresh")
        XCTAssertEqual(
            credential?.sourcePath,
            directory.appendingPathComponent("auth.v2.loginkeychain").path
        )
    }

    func testFactoryDroidPersistsRotatedEncryptedCredentialWithoutDroppingFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyData = Data(repeating: 9, count: 32)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 10, count: 16))
        let cleartext = Data(#"{"access_token":"old-token","refresh_token":"old-refresh","active_organization_id":"org-123","unknown":"keep"}"#.utf8)
        let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: keyData), nonce: nonce)
        let encrypted = [
            Data(nonce).base64EncodedString(),
            sealed.tag.base64EncodedString(),
            sealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":")
        let credentialsURL = directory.appendingPathComponent("auth.v2.file")
        try Data(encrypted.utf8).write(to: credentialsURL)
        try Data(keyData.base64EncodedString().utf8).write(to: directory.appendingPathComponent("auth.v2.key"))

        XCTAssertTrue(FactoryDroidCredentialReader.canPersistRefresh(
            sourcePath: credentialsURL.path,
            expectedRefreshToken: "old-refresh"
        ))
        XCTAssertTrue(try FactoryDroidCredentialReader.persistRefresh(
            sourcePath: credentialsURL.path,
            expectedRefreshToken: "old-refresh",
            accessToken: "new-token",
            refreshToken: "new-refresh"
        ))

        let updated = try String(contentsOf: credentialsURL, encoding: .utf8)
        let decrypted = try XCTUnwrap(FactoryDroidCredentialReader.decryptCredential(
            encrypted: updated,
            keyData: keyData,
            sourcePath: credentialsURL.path
        ))
        XCTAssertEqual(decrypted.accessToken, "new-token")
        XCTAssertEqual(decrypted.refreshToken, "new-refresh")
        let pieces = updated.split(separator: ":")
        let updatedNonce = try AES.GCM.Nonce(data: XCTUnwrap(Data(base64Encoded: String(pieces[0]))))
        let updatedTag = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let updatedCiphertext = try XCTUnwrap(Data(base64Encoded: String(pieces[2])))
        let updatedBox = try AES.GCM.SealedBox(
            nonce: updatedNonce,
            ciphertext: updatedCiphertext,
            tag: updatedTag
        )
        let updatedCleartext = try AES.GCM.open(updatedBox, using: SymmetricKey(data: keyData))
        let updatedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedCleartext) as? [String: String])
        XCTAssertEqual(updatedJSON["unknown"], "keep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("auth.v2.write.lock").path
        ))
        XCTAssertFalse(try FactoryDroidCredentialReader.persistRefresh(
            sourcePath: credentialsURL.path,
            expectedRefreshToken: "old-refresh",
            accessToken: "stale-token",
            refreshToken: nil
        ))
    }

    func testFactoryDroidCoordinatesCredentialReplacementWithDroidWriteLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentialsURL = directory.appendingPathComponent("auth.encrypted")
        let lockURL = directory.appendingPathComponent("auth.v2.write.lock")
        try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(to: credentialsURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let owner = try JSONSerialization.data(withJSONObject: [
            "token": "droid-writer",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ])
        try owner.write(to: lockURL.appendingPathComponent("owner.json"))

        let writerFinished = expectation(description: "Droid writer finished")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? Data(#"{"access_token":"droid-token","refresh_token":"droid-refresh"}"#.utf8)
                .write(to: credentialsURL)
            try? FileManager.default.removeItem(at: lockURL)
            writerFinished.fulfill()
        }

        XCTAssertFalse(try FactoryDroidCredentialReader.persistRefresh(
            sourcePath: credentialsURL.path,
            expectedRefreshToken: "old-refresh",
            accessToken: "quotio-token",
            refreshToken: "quotio-refresh"
        ))
        wait(for: [writerFinished], timeout: 1)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: credentialsURL)) as? [String: String]
        XCTAssertEqual(stored?["access_token"], "droid-token")
        XCTAssertEqual(stored?["refresh_token"], "droid-refresh")
    }

    func testFactoryDroidPreflightRequiresWritableCredentialDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let credentialsURL = directory.appendingPathComponent("auth.encrypted")
        try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(to: credentialsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        XCTAssertFalse(FactoryDroidCredentialReader.canPersistRefresh(
            sourcePath: credentialsURL.path,
            expectedRefreshToken: "old-refresh"
        ))
    }

    func testFactoryDroidReclaimsWriteLockFromTerminatedOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentialsURL = directory.appendingPathComponent("auth.encrypted")
        let lockURL = directory.appendingPathComponent("auth.v2.write.lock")
        try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(to: credentialsURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let owner = try JSONSerialization.data(withJSONObject: [
            "token": "abandoned-writer",
            "pid": Int32.max,
        ])
        try owner.write(to: lockURL.appendingPathComponent("owner.json"))

        XCTAssertTrue(try FactoryDroidCredentialReader.persistRefresh(
            sourcePath: credentialsURL.path,
            expectedRefreshToken: "old-refresh",
            accessToken: "new-token",
            refreshToken: "new-refresh"
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: credentialsURL)) as? [String: String]
        XCTAssertEqual(stored?["access_token"], "new-token")
        XCTAssertEqual(stored?["refresh_token"], "new-refresh")
    }

    func testFactoryDroidRefusesRefreshWhenCredentialDestinationIsSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("auth.encrypted")
        try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(FactoryDroidCredentialReader.canPersistRefresh(
            sourcePath: link.path,
            expectedRefreshToken: "old-refresh"
        ))
    }

    func testFactoryDroidBuildsDroidCompatibleRefreshRequest() throws {
        let request = FactoryDroidQuotaFetcher.makeRefreshRequest(
            refreshToken: "refresh + token",
            organizationID: "org-123"
        )
        let body = try XCTUnwrap(request.httpBody)
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        let values = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value) })

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("refresh_token=refresh%20%2B%20token"))
        XCTAssertEqual(values["grant_type"], "refresh_token")
        XCTAssertEqual(values["refresh_token"], "refresh + token")
        XCTAssertEqual(values["client_id"], "client_01HNM792M5G5G1A2THWPXKFMXB")
        XCTAssertEqual(values["organization_id"], "org-123")
    }

    func testFactoryDroidOnlyRetriesUnauthorizedResponses() {
        XCTAssertTrue(FactoryDroidQuotaFetcher.shouldRefresh(statusCode: 401, didRefresh: false))
        XCTAssertFalse(FactoryDroidQuotaFetcher.shouldRefresh(statusCode: 403, didRefresh: false))
        XCTAssertFalse(FactoryDroidQuotaFetcher.shouldRefresh(statusCode: 401, didRefresh: true))
    }

    func testFactoryDroidMapsStandardCoreAndExtraUsage() throws {
        let payload = Data(#"""
        {
          "usesTokenRateLimitsBilling": true,
          "limits": {
            "standard": {
              "fiveHour": {"usedPercent": 100, "windowEnd": "2026-07-20T17:59:00.865Z", "secondsRemaining": 5382},
              "weekly": {"usedPercent": 63, "windowEnd": "2026-07-25T16:37:06.931Z", "secondsRemaining": 432468},
              "monthly": {"usedPercent": 16, "windowEnd": "2026-08-17T16:37:06.931Z", "secondsRemaining": 2419668}
            },
            "core": {
              "fiveHour": {"usedPercent": 100, "windowEnd": "2026-07-20T19:01:10.798Z", "secondsRemaining": 9112},
              "weekly": {"usedPercent": 51, "windowEnd": "2026-07-27T14:01:10.798Z", "secondsRemaining": 595912},
              "monthly": {"usedPercent": 19, "windowEnd": "2026-08-19T14:01:10.798Z", "secondsRemaining": 2583112}
            }
          },
          "extraUsageBalanceCents": 0,
          "overagePreference": "droidCore",
          "extraUsageAllowed": true
        }
        """#.utf8)
        let response = try JSONDecoder().decode(FactoryDroidQuotaResponse.self, from: payload)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-20T18:30:00Z"))

        let quota = FactoryDroidQuotaMapper.map(response, now: now)

        XCTAssertEqual(quota.models.count, 7)
        XCTAssertEqual(quota.models.first(where: { $0.name == "factory-standard-five-hour" })?.percentage, 100)
        XCTAssertEqual(quota.models.first(where: { $0.name == "factory-core-five-hour" })?.percentage, 0)
        XCTAssertEqual(quota.models.first(where: { $0.name == "factory-standard-weekly" })?.percentage, 37)
        XCTAssertEqual(quota.models.first(where: { $0.name == "factory-core-weekly" })?.percentage, 49)
        let sections = FactoryDroidQuotaSection.sections(from: quota.models)
        XCTAssertEqual(sections.map(\.group), [.standard, .core])
        XCTAssertEqual(sections.map { $0.models.count }, [3, 3])
        XCTAssertEqual(
            sections[0].models.map(\.name),
            ["factory-standard-five-hour", "factory-standard-weekly", "factory-standard-monthly"]
        )
        XCTAssertEqual(
            sections[1].models.map(\.name),
            ["factory-core-five-hour", "factory-core-weekly", "factory-core-monthly"]
        )
        XCTAssertEqual(
            quota.models.first(where: { $0.name == "factory-extra-balance" })?.presentation,
            .amount(value: 0, unit: .usd, semantics: .balance)
        )
        XCTAssertNil(quota.models.first(where: { $0.name == "factory-extra-usage" }))
    }

    func testFactoryDroidAuthMeExtractsUserProfileEmail() throws {
        let response = try JSONDecoder().decode(
            FactoryDroidAuthMeResponse.self,
            from: Data(#"{"organization":{"id":"org-123"},"userProfile":{"email":" factory@example.com ","firstName":"Factory"}}"#.utf8)
        )
        let missing = try JSONDecoder().decode(
            FactoryDroidAuthMeResponse.self,
            from: Data(#"{"userProfile":{"email":"  "}}"#.utf8)
        )

        XCTAssertEqual(response.email, "factory@example.com")
        XCTAssertNil(missing.email)
    }

    func testFactoryDroidMapsLegacyBillingStatus() throws {
        let response = try JSONDecoder().decode(
            FactoryDroidQuotaResponse.self,
            from: Data(#"{"usesTokenRateLimitsBilling":false}"#.utf8)
        )

        let quota = FactoryDroidQuotaMapper.map(response)

        XCTAssertEqual(quota.models.first?.name, "factory-billing-mode")
        XCTAssertTrue(quota.models.first?.isStandaloneMetric == true)
    }

    func testZAIQuotaMappingClassifiesWindowsAndSearches() {
        let data = GLMQuotaData(limits: [
            GLMLimit(type: "TOKENS_LIMIT", unit: 3, number: 5, usage: 100, currentValue: 20, remaining: 80, percentage: 20, usageDetails: nil, nextResetTime: nil),
            GLMLimit(type: "TOKENS_LIMIT", unit: 4, number: 1, usage: 100, currentValue: 30, remaining: 70, percentage: 30, usageDetails: nil, nextResetTime: nil),
            GLMLimit(type: "TOKENS_LIMIT", unit: 4, number: 7, usage: 100, currentValue: 60, remaining: 40, percentage: 60, usageDetails: nil, nextResetTime: nil),
            GLMLimit(type: "TOKENS_LIMIT", unit: 5, number: 1, usage: 100, currentValue: 10, remaining: 90, percentage: 10, usageDetails: nil, nextResetTime: nil),
            GLMLimit(type: "TIME_LIMIT", unit: 4, number: 1, usage: 1000, currentValue: 125, remaining: 875, percentage: 12.5, usageDetails: nil, nextResetTime: nil),
        ])

        let quota = GLMQuotaFetcher.mapQuotaData(data, planName: "GLM Coding Pro")

        XCTAssertEqual(quota.planType, "GLM Coding Pro")
        XCTAssertEqual(quota.models.map(\.name), ["zai-session", "zai-daily", "zai-weekly", "zai-monthly", "zai-web-searches"])
        XCTAssertEqual(quota.models[0].percentage, 80)
        XCTAssertEqual(quota.models[1].percentage, 70)
        XCTAssertEqual(quota.models[2].percentage, 40)
        XCTAssertEqual(quota.models[3].percentage, 90)
        XCTAssertEqual(quota.models[4].presentation, .progress(used: 125, limit: 1000, unit: .searches))
        XCTAssertEqual(GLMQuotaFetcher.apiRoot(from: "https://bigmodel.cn/api/paas/v4"), "https://bigmodel.cn")
    }

    func testZAIQuotaResponseDecodesOptionalLiveFields() throws {
        let payload = Data(#"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":25},{"type":"TIME_LIMIT","usage":1000,"currentValue":0}]},"success":true}"#.utf8)

        let response = try JSONDecoder().decode(GLMQuotaResponse.self, from: payload)
        let quota = GLMQuotaFetcher.mapQuotaData(try XCTUnwrap(response.data), planName: nil)

        XCTAssertEqual(quota.models.map(\.name), ["zai-weekly", "zai-web-searches"])
        XCTAssertEqual(quota.models[1].presentation, .progress(used: 0, limit: 1000, unit: .searches))
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

    func testDevinRejectedCredentialReturnsForbiddenQuota() throws {
        XCTAssertTrue(try XCTUnwrap(DevinQuotaFetcher.quotaResult(data: Data(), statusCode: 401)).isForbidden)
        XCTAssertTrue(try XCTUnwrap(DevinQuotaFetcher.quotaResult(data: Data(), statusCode: 403)).isForbidden)
        XCTAssertNil(DevinQuotaFetcher.quotaResult(data: Data(), statusCode: 500))
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
        let quotedHash = DevinQuotaFetcher.parseCredentialsTOML("""
        windsurf_api_key = "native#token" # account credential
        api_server_url = "https://server.codeium.test/path#fragment" # API endpoint
        """)

        XCTAssertEqual(native, DevinCredential(apiKey: "native-token", apiServerURL: "https://server.codeium.test"))
        XCTAssertNil(insecure?.apiServerURL)
        XCTAssertEqual(
            quotedHash,
            DevinCredential(apiKey: "native#token", apiServerURL: "https://server.codeium.test/path#fragment")
        )
    }

    func testDevinReadsSQLiteAppCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("state.vscdb").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer {
            sqlite3_close(database)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
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

    func testGrokUsesDefaultClientIDWhenEntryKeyHasNoSuffix() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "account-without-client": ["key": "token", "refresh_token": "refresh"],
        ])
        try data.write(to: url)

        let candidate = try XCTUnwrap(GrokQuotaFetcher.loadCandidates(path: url.path).first)

        XCTAssertEqual(candidate.clientID, GrokQuotaFetcher.defaultClientID)
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

    func testGrokQuotaResultMarksRejectedCredentialsAndSetsDisplayName() throws {
        let forbidden = try XCTUnwrap(GrokQuotaFetcher.quotaResult(
            data: Data(),
            statusCode: 403,
            plan: nil,
            displayName: "person@example.com"
        ))
        XCTAssertTrue(forbidden.isForbidden)
        XCTAssertEqual(forbidden.accountDisplayName, "person@example.com")

        let billing = try JSONSerialization.data(withJSONObject: [
            "config": [
                "creditUsagePercent": 25,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2030-01-08T00:00:00Z"],
            ],
        ])
        let quota = try XCTUnwrap(GrokQuotaFetcher.quotaResult(
            data: billing,
            statusCode: 200,
            plan: "SuperGrok",
            displayName: "person@example.com"
        ))
        XCTAssertEqual(quota.accountDisplayName, "person@example.com")
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

    func testOpenRouterPlanLabelsUseLocalization() throws {
        let previousLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("vi", forKey: "appLanguage")
        defer { UserDefaults.standard.set(previousLanguage, forKey: "appLanguage") }
        let key = OpenRouterEndpointResult(
            data: try JSONSerialization.data(withJSONObject: ["data": ["is_free_tier": true]]),
            statusCode: 200
        )
        let quota = try XCTUnwrap(OpenRouterQuotaMapper.map(
            credits: OpenRouterEndpointResult(data: nil, statusCode: 500),
            key: key
        ))

        XCTAssertEqual(quota.planType, "Gói miễn phí")
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
            key: OpenRouterEndpointResult(data: nil, statusCode: 503)
        ))
        XCTAssertTrue(forbidden.isForbidden)
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
            let vault = MonitorCredentialVault(metadata: MonitorMetadataStore(url: metadataURL))
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

    func testAmpConfigurationMergePreservesNativeAndUnknownSecrets() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "apiKey@https://ampcode.com/": "native-token",
            "unrelated": "preserve-me",
        ])

        let merged = try AgentConfigurationService.mergedAmpJSON(
            existing: existing,
            updates: ["apiKey@http://localhost:8317": "proxy-token"]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: String])

        XCTAssertEqual(object["apiKey@https://ampcode.com/"], "native-token")
        XCTAssertEqual(object["unrelated"], "preserve-me")
        XCTAssertEqual(object["apiKey@http://localhost:8317"], "proxy-token")
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
    func testLegacyGeminiFallbackEntryMigratesWithoutDroppingConfiguration() throws {
        let modelID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "isRouteCachingEnabled": false,
            "virtualModels": [[
                "id": modelID.uuidString,
                "name": "fast-model",
                "fallbackEntries": [
                    ["id": UUID().uuidString, "provider": "gemini-cli", "modelId": "gemini-3-flash-preview", "priority": 1],
                    ["id": UUID().uuidString, "provider": "codex", "modelId": "gpt-5", "priority": 2],
                ],
                "isEnabled": true,
            ]],
        ])

        let configuration = try JSONDecoder().decode(FallbackConfiguration.self, from: data)

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertFalse(configuration.isRouteCachingEnabled)
        XCTAssertEqual(configuration.virtualModels.first?.id, modelID)
        XCTAssertEqual(configuration.virtualModels.first?.fallbackEntries.map(\.provider), [.antigravity, .codex])
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

    func testQuotaDerivedIDEAccountsAllowDeletion() {
        // Cursor/Trae accounts imported from local IDE databases must be deletable (issue #213).
        for provider in [AIProvider.cursor, .trae] {
            let account = MonitorRefreshCoordinator.makeQuotaDerivedAccount(
                provider: provider,
                accountKey: "user@example.com",
                source: .localIDE,
                disabledIDs: []
            )
            XCTAssertTrue(account.canDelete, "\(provider.rawValue) account should be deletable")
        }

        // Quota-derived placeholders for credential-backed providers would resurrect
        // on the next discovery pass, so they must stay non-deletable.
        for (provider, source) in [(AIProvider.claude, MonitorAccountSource.nativeCredential), (.amp, .apiKey)] {
            let account = MonitorRefreshCoordinator.makeQuotaDerivedAccount(
                provider: provider,
                accountKey: "user@example.com",
                source: source,
                disabledIDs: []
            )
            XCTAssertFalse(account.canDelete, "\(provider.rawValue) account should not be deletable")
        }
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

    private func ideQuota(_ percentage: Double) -> ProviderQuotaData {
        ProviderQuotaData(
            models: [ModelQuota(name: "gpt", percentage: percentage, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: 1234)
        )
    }

    /// A credential vault with nothing in it, so Monitor discovery in these tests depends
    /// only on the injected snapshot/metadata files and never on the host Keychain.
    private struct EmptyCredentialVault: MonitorCredentialStore {
        func accounts() async -> [MonitorAccount] { [] }
        func credential(for accountID: String) async -> MonitorOAuthCredential? { nil }
        func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { nil }
        func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws {}
        func delete(accountID: String) async {}
    }

    private func makeIsolatedCoordinator(
        snapshots: URL,
        metadata: URL
    ) -> MonitorRefreshCoordinator {
        MonitorRefreshCoordinator(
            discovery: MonitorAccountDiscovery(
                vault: EmptyCredentialVault(),
                metadata: MonitorMetadataStore(url: metadata)
            ),
            snapshots: MonitorSnapshotStore(url: snapshots)
        )
    }

    /// Reproduces the exact resurrection sequence from issue #213: import Cursor in
    /// Monitor mode, delete the auto-detected row while a different mode is active, then
    /// re-enter Monitor mode. `initializeQuotaOnlyMode()` bootstraps from the snapshot, so
    /// the deletion only sticks if it cleared the snapshot outside Monitor mode too.
    func testDeletingIDEAccountOutsideMonitorModeSurvivesMonitorBootstrap() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshots = directory.appendingPathComponent("snapshots-v1.json")
        let metadata = directory.appendingPathComponent("accounts-v1.json")

        // 1. Monitor mode imports Cursor and persists it in the Monitor snapshot, next to
        //    an unrelated Monitor-only account.
        await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadata).finish(quotas: [
            .cursor: ["cursor@example.com": ideQuota(50)],
            .codex: ["codex@example.com": ideQuota(42)],
        ])

        let imported = await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadata).bootstrap()
        XCTAssertNotNil(imported.quotas[.cursor]?["cursor@example.com"])
        XCTAssertTrue(
            imported.accounts.contains { $0.provider == .cursor && $0.accountKey == "cursor@example.com" },
            "Precondition: the Monitor snapshot restores the imported Cursor account"
        )

        // 2. Local Proxy mode: deleting the auto-detected Cursor row. This is the call
        //    `QuotaViewModel.deleteAutoDetectedAccount` makes, and it runs regardless of
        //    the active mode.
        await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadata)
            .forgetSnapshotAccount(provider: .cursor, accountKey: "cursor@example.com")

        // 3. Back in Monitor mode: `initializeQuotaOnlyMode()` calls `bootstrap()`.
        let rebootstrapped = await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadata).bootstrap()
        XCTAssertNil(
            rebootstrapped.quotas[.cursor],
            "Deleted Cursor account must not come back from the Monitor snapshot"
        )
        XCTAssertFalse(
            rebootstrapped.accounts.contains { $0.provider == .cursor },
            "Deleted Cursor account must not reappear as a Monitor account"
        )
        // The delete must not take the rest of the Monitor snapshot with it, and must not
        // replace it with the quota data of whichever mode performed the deletion.
        XCTAssertEqual(rebootstrapped.quotas[.codex]?["codex@example.com"]?.models.first?.percentage, 42)
    }

    /// The targeted removal must not rewrite the snapshot from the deleting mode's quota
    /// data: entries for other providers, and other accounts of the same provider, stay
    /// exactly as they were written by Monitor mode.
    func testForgettingIDEAccountLeavesUnrelatedSnapshotEntriesIntact() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshots = directory.appendingPathComponent("snapshots-v1.json")
        let metadata = directory.appendingPathComponent("accounts-v1.json")

        await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadata).finish(quotas: [
            .cursor: ["gone@example.com": ideQuota(10), "kept@example.com": ideQuota(20)],
            .trae: ["trae@example.com": ideQuota(30)],
        ])

        await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadata)
            .forgetSnapshotAccount(provider: .cursor, accountKey: "gone@example.com")

        let reloaded = await MonitorSnapshotStore(url: snapshots).load()
        XCTAssertNil(reloaded[.cursor]?["gone@example.com"])
        XCTAssertEqual(reloaded[.cursor]?["kept@example.com"]?.models.first?.percentage, 20)
        XCTAssertEqual(reloaded[.trae]?["trae@example.com"]?.models.first?.percentage, 30)
    }

    /// The Monitor row carries a trimmed account key while the snapshot stores the key
    /// verbatim, so the removal has to match on the identity Monitor dedupes on rather
    /// than on an exact string.
    func testSnapshotRemovalMatchesMonitorAccountIdentity() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("snapshots-v1.json")
        let store = MonitorSnapshotStore(url: url)

        await store.store([.cursor: [" Cursor@Example.com ": ideQuota(50)]])
        let account = MonitorAccount.make(
            provider: .cursor,
            accountKey: " Cursor@Example.com ",
            source: .localIDE
        )

        let removed = await store.removeAccount(provider: .cursor, accountKey: account.accountKey)

        XCTAssertTrue(removed)
        let reloaded = await MonitorSnapshotStore(url: url).load()
        XCTAssertNil(reloaded[.cursor], "Deleted Cursor account must not survive a reload")
    }

    /// Deleting an imported IDE account must also drop the Monitor disabled flag it left
    /// in `accounts-v1.json`; otherwise a later re-scan brings the account back disabled.
    func testForgettingIDEAccountClearsItsMonitorDisabledFlag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshots = directory.appendingPathComponent("snapshots-v1.json")
        let metadataURL = directory.appendingPathComponent("accounts-v1.json")
        let metadata = MonitorMetadataStore(url: metadataURL)

        let account = MonitorAccount.make(
            provider: .cursor,
            accountKey: "cursor@example.com",
            source: .localIDE,
            canDelete: true
        )
        try await metadata.setDisabled(true, accountID: account.id)
        await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadataURL)
            .finish(quotas: [.cursor: [account.accountKey: ideQuota(50)]])

        await makeIsolatedCoordinator(snapshots: snapshots, metadata: metadataURL)
            .forgetSnapshotAccount(provider: .cursor, accountKey: account.accountKey)

        let disabled = await MonitorMetadataStore(url: metadataURL).disabledAccountIDs()
        XCTAssertFalse(disabled.contains(account.id), "Deleted account must not keep a disabled flag")
    }

    /// The delete affordance keys off a named IDE-import capability rather than
    /// `usesBrowserAuth` doubling as "is deletable"; it is derived from the existing
    /// traits so a new IDE edition inherits it automatically.
    func testImportedFromLocalIDECapabilityStaysDerivedFromProviderTraits() {
        for provider in AIProvider.allCases {
            XCTAssertEqual(
                provider.isImportedFromLocalIDE,
                provider.usesBrowserAuth && !provider.supportsManualAuth,
                "\(provider.rawValue) IDE-import capability must stay derived from the existing traits"
            )
        }
        for provider in [AIProvider.cursor, .trae] {
            XCTAssertTrue(provider.isImportedFromLocalIDE, "\(provider.rawValue) is scanned from a local IDE")
        }
        // Providers that also refuse manual auth but are added from their own storage
        // must not become deletable through this path.
        for provider in [AIProvider.devin, .grok, .glm, .clinePass] {
            XCTAssertFalse(provider.isImportedFromLocalIDE, "\(provider.rawValue) is not an IDE import")
        }
    }

    func testQuotaDisplayNameEnrichmentPreservesFactoryAccountIdentity() {
        let account = MonitorAccount.make(
            provider: .factoryDroid,
            accountKey: "org-123",
            displayName: "Factory Droid",
            source: .nativeCredential
        )
        let quota = ProviderQuotaData(accountDisplayName: "factory@example.com")

        let enriched = MonitorRefreshCoordinator.applyingQuotaDisplayNames(
            [account],
            quotas: [.factoryDroid: [account.accountKey: quota]]
        )

        XCTAssertEqual(enriched.first?.displayName, "factory@example.com")
        XCTAssertEqual(enriched.first?.accountKey, account.accountKey)
        XCTAssertEqual(enriched.first?.id, account.id)
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
