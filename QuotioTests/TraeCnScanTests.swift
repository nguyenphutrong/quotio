import CommonCrypto
import CryptoKit
import XCTest
@testable import Quotio

/// Builds `iCubeAuthInfo://icube.cloudide` envelopes for the tests below.
///
/// The key material is re-derived here from `luckymiaow/trae-mate`
/// (`src-tauri/src/trae_auth.rs`), which stores the secret obfuscated as two 64-byte
/// halves XORed together at runtime. `TraeAuthEnvelope` carries the already-XORed
/// constant taken from `koi128bit/WorkBuddy-Switch`
/// (`Sources/OpenUsage/TraeSupport.swift`). Because this fixture encodes with trae-mate's
/// halves and production decodes with WorkBuddy-Switch's constant, every test that round
/// trips through it is also a cross-check that the two independent implementations agree —
/// if the shipped constant were wrong, these tests would fail.
///
/// The *format* is reproduced from those two sources. The *values* below are synthetic:
/// no real Trae CN credential was captured, and none is needed, because what is under test
/// is the decode contract, not a particular account.
private enum TraeEnvelopeFixture {
    /// trae-mate `LEFT_SECRET`
    static let leftSecret: [UInt8] = [
        82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
        124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
        84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
        8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37
    ]

    /// trae-mate `RIGHT_SECRET`
    static let rightSecret: [UInt8] = [
        31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
        96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
        160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
        23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125
    ]

    static let header = Data([116, 99, 5, 16, 0, 0])

    static var secret: Data {
        Data(zip(leftSecret, rightSecret).map { $0 ^ $1 })
    }

    /// A fixed key keeps the produced envelope deterministic across runs.
    static let randomKey = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    static func encode(payload: Data, randomKey: Data = randomKey) throws -> String {
        var authenticated = Data(SHA512.hash(data: payload))
        authenticated.append(payload)

        var seed = Data(SHA512.hash(data: randomKey))
        seed.append(secret)
        let material = Data(SHA512.hash(data: seed))

        let ciphertext = try encryptAES128CBC(
            authenticated,
            key: Data(material.prefix(16)),
            iv: Data(material.dropFirst(16).prefix(16))
        )

        var blob = header
        blob.append(randomKey)
        blob.append(ciphertext)
        return blob.base64EncodedString()
    }

    private static func encryptAES128CBC(_ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "TraeEnvelopeFixture", code: Int(status))
        }
        output.count = outputLength
        return output
    }
}

/// Drives the *actual* Trae CN scan — storage.json read, envelope decode, account
/// extraction, quota parsing — rather than the descriptors that describe it (issue #265).
final class TraeCnScanTests: XCTestCase {

    // MARK: - Fixtures

    /// The auth payload shape both reference implementations read: `token`, `refreshToken`,
    /// `userId`, `host` at the top level, identity under `account`.
    private func authPayloadJSON(host: String?) -> Data {
        var object: [String: Any] = [
            "token": "cn-access-token",
            "refreshToken": "cn-refresh-token",
            "userId": "7412345678901234567",
            "account": [
                "email": "scan-fixture@example.cn",
                "username": "scan-fixture"
            ]
        ]
        if let host {
            object["host"] = host
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Writes a storage.json containing `blob` and returns overrides pointing the real
    /// fetcher at it (plus a directory that stands in for the installed app bundle).
    private func makeInstall(blob: String) throws -> TraeScanPathOverrides {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trae-cn-scan-\(UUID().uuidString)", isDirectory: true)
        let globalStorage = root
            .appendingPathComponent("Trae CN.app/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storage: [String: Any] = [
            "iCubeAuthInfo://icube.cloudide": blob,
            "telemetry.machineId": "fixture-machine-id"
        ]
        let storageURL = globalStorage.appendingPathComponent("storage.json")
        try JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
            .write(to: storageURL)

        return TraeScanPathOverrides(
            storageJSONPath: storageURL.path,
            appPaths: [root.appendingPathComponent("Trae CN.app").path]
        )
    }

    // MARK: - Envelope decode (the format current clients actually write)

    /// The real scan must decode the encrypted envelope current Trae clients write and
    /// surface the account, not bail out because the value is not plaintext JSON.
    func testScanDecodesEncryptedStorageAndExtractsAccount() async throws {
        let blob = try TraeEnvelopeFixture.encode(
            payload: authPayloadJSON(host: "https://api.trae.com.cn")
        )
        // Guards against the fixture silently degrading to the plaintext branch.
        XCTAssertFalse(blob.hasPrefix("{"))

        let fetcher = TraeQuotaFetcher(variant: .cn, pathOverrides: try makeInstall(blob: blob))

        let auth = await fetcher.readAuthFromStorageJson()

        let unwrapped = try XCTUnwrap(auth, "The encrypted envelope must decode")
        XCTAssertEqual(unwrapped.accessToken, "cn-access-token")
        XCTAssertEqual(unwrapped.refreshToken, "cn-refresh-token")
        XCTAssertEqual(unwrapped.userId, "7412345678901234567")
        XCTAssertEqual(unwrapped.email, "scan-fixture@example.cn")
        XCTAssertEqual(unwrapped.username, "scan-fixture")
        XCTAssertEqual(unwrapped.apiHost, "https://api.trae.com.cn")
    }

    /// A storage.json written by an older client still holds plaintext JSON; that path must
    /// keep working alongside the envelope.
    func testScanStillDecodesLegacyPlaintextStorage() async throws {
        let plaintext = String(data: authPayloadJSON(host: "https://api.trae.cn"), encoding: .utf8)!
        let fetcher = TraeQuotaFetcher(
            variant: .cn,
            pathOverrides: try makeInstall(blob: plaintext)
        )

        let read = await fetcher.readAuthFromStorageJson()
        let auth = try XCTUnwrap(read)
        XCTAssertEqual(auth.email, "scan-fixture@example.cn")
        XCTAssertEqual(auth.apiHost, "https://api.trae.cn")
    }

    /// The plaintext inside the envelope is prefixed with a SHA-512 digest of the payload.
    /// A modified payload must be rejected rather than parsed.
    func testTamperedEnvelopePayloadIsRejected() throws {
        let payload = authPayloadJSON(host: nil)
        let blob = try TraeEnvelopeFixture.encode(payload: payload)
        var bytes = Data(base64Encoded: blob)!
        // Flip a bit in the ciphertext, past the 6-byte header and 32-byte key.
        bytes[bytes.count - 1] ^= 0xFF

        XCTAssertThrowsError(try TraeAuthEnvelope.decrypt(bytes.base64EncodedString()))
    }

    /// A value that is neither plaintext JSON nor a valid envelope must not be treated as
    /// an account.
    func testGarbageStorageValueIsRejected() throws {
        XCTAssertThrowsError(try TraeAuthEnvelope.decodeAuthInfo("not-an-envelope")) { error in
            XCTAssertEqual(error as? TraeAuthEnvelope.DecodeError, .malformedEnvelope)
        }
    }

    // MARK: - API host resolution

    /// No public source confirms Trae CN's API host, so there is no hardcoded default: the
    /// host must come from the decoded blob.
    func testCnHostComesFromTheAuthBlob() {
        XCTAssertNil(
            TraeVariantDescriptor.cn.defaultAPIHost,
            "Trae CN must not ship a guessed API host"
        )
        XCTAssertNil(
            TraeQuotaFetcher.resolveAPIHost(authHost: nil, variant: .cn),
            "Without a host in the blob there is nothing verified to call"
        )
        XCTAssertEqual(
            TraeQuotaFetcher.resolveAPIHost(authHost: "https://api.trae.com.cn/", variant: .cn),
            "https://api.trae.com.cn"
        )
        XCTAssertEqual(
            TraeQuotaFetcher.resolveAPIHost(authHost: "api.trae.cn", variant: .cn),
            "https://api.trae.cn"
        )
    }

    /// The international edition keeps its existing verified fallback host.
    func testInternationalHostFallbackIsUnchanged() {
        XCTAssertEqual(
            TraeQuotaFetcher.resolveAPIHost(authHost: nil, variant: .international),
            "https://api-sg-central.trae.ai"
        )
        XCTAssertEqual(
            TraeQuotaFetcher.resolveAPIHost(authHost: "https://api-us-east.trae.ai", variant: .international),
            "https://api-us-east.trae.ai"
        )
    }

    /// storage.json is an ordinary user-writable file. A host outside Trae's domains, or a
    /// plaintext scheme, must not receive the bearer token.
    func testUnsafeHostInAuthBlobIsRejected() {
        XCTAssertNil(TraeQuotaFetcher.resolveAPIHost(authHost: "https://evil.example.com", variant: .cn))
        XCTAssertNil(TraeQuotaFetcher.resolveAPIHost(authHost: "http://api.trae.cn", variant: .cn))
        XCTAssertNil(TraeQuotaFetcher.resolveAPIHost(authHost: "https://trae.cn.evil.example", variant: .cn))
    }

    // MARK: - Quota endpoints

    /// The CN endpoint order is taken from public CN integrations rather than inherited
    /// from the international v1 entitlement endpoint, which no CN source corroborates.
    func testCnQuotaEndpointsAreNotInheritedFromInternational() {
        XCTAssertEqual(
            TraeVariantDescriptor.cn.quotaEndpointPaths,
            [
                "trae/api/v2/pay/ide_user_ent_usage",
                "trae/api/v1/pay/ide_user_ent_usage",
                "trae/api/v1/pay/user_current_entitlement_list"
            ]
        )
        XCTAssertEqual(
            TraeVariantDescriptor.cn.quotaEndpointPaths.first,
            "trae/api/v2/pay/ide_user_ent_usage"
        )
        XCTAssertEqual(
            TraeVariantDescriptor.international.quotaEndpointPaths,
            ["trae/api/v1/pay/user_current_entitlement_list"]
        )
    }

    // MARK: - Decoded account → quota

    private func entitlementPack() -> [String: Any] {
        [
            "status": 1,
            "entitlement_base_info": [
                "product_type": 1,
                "end_time": 1_800_000_000,
                "quota": [
                    "premium_model_fast_request_limit": 600,
                    "premium_model_slow_request_limit": 100,
                    "advanced_model_request_limit": 50,
                    "auto_completion_limit": 2000
                ]
            ],
            "usage": [
                "premium_model_fast_amount": 150,
                "premium_model_slow_amount": 10,
                "advanced_model_amount": 5,
                "auto_completion_amount": 500
            ]
        ]
    }

    /// A decoded account must survive quota detection: the entitlement response the v1
    /// endpoint returns is parsed into the account-keyed quota the UI shows.
    func testDecodedAccountProducesQuotaFromEntitlementListResponse() async throws {
        let blob = try TraeEnvelopeFixture.encode(
            payload: authPayloadJSON(host: "https://api.trae.com.cn")
        )
        let fetcher = TraeQuotaFetcher(variant: .cn, pathOverrides: try makeInstall(blob: blob))
        let read = await fetcher.readAuthFromStorageJson()
        let auth = try XCTUnwrap(read)

        let body = try JSONSerialization.data(
            withJSONObject: ["user_entitlement_pack_list": [entitlementPack()]]
        )
        let info = try XCTUnwrap(TraeQuotaFetcher.parseQuotaResponse(body, authData: auth))
        let quotas = TraeQuotaFetcher.makeProviderQuota(info: info, variant: .cn)

        let account = try XCTUnwrap(quotas["scan-fixture@example.cn"], "The scanned account keys the quota")
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(account.planType, "Pro")

        let fast = try XCTUnwrap(account.models.first { $0.name == "premium-fast" })
        XCTAssertEqual(fast.limit, 600)
        XCTAssertEqual(fast.used, 150)
        XCTAssertEqual(fast.remaining, 450)
        XCTAssertEqual(fast.percentage, 75, accuracy: 0.001)
        XCTAssertEqual(
            Set(account.models.map(\.name)),
            ["premium-fast", "premium-slow", "advanced-model", "auto-completion"]
        )
    }

    /// The `ide_user_ent_usage` endpoints return the same pack objects, but the key that
    /// holds them is not documented. Packs are therefore also found structurally, so a
    /// successfully decoded account does not fail quota detection on a different envelope
    /// key.
    func testQuotaIsParsedWhenPacksAreNestedUnderAnotherKey() throws {
        let auth = TraeAuthData(
            accessToken: "cn-access-token",
            refreshToken: nil,
            email: "scan-fixture@example.cn",
            userId: "7412345678901234567",
            apiHost: "https://api.trae.com.cn",
            username: "scan-fixture"
        )
        let body = try JSONSerialization.data(
            withJSONObject: ["data": ["ent_usage_list": [entitlementPack()]]]
        )

        let info = try XCTUnwrap(TraeQuotaFetcher.parseQuotaResponse(body, authData: auth))
        let quotas = TraeQuotaFetcher.makeProviderQuota(info: info, variant: .cn)
        let account = try XCTUnwrap(quotas["scan-fixture@example.cn"])
        XCTAssertEqual(account.models.first { $0.name == "premium-fast" }?.used, 150)
    }

    /// A response with no recognisable entitlement pack must not be reported as a quota.
    func testUnrecognisedQuotaResponseIsRejected() throws {
        let auth = TraeAuthData(
            accessToken: "t", refreshToken: nil, email: "scan-fixture@example.cn",
            userId: "1", apiHost: nil, username: nil
        )
        let body = try JSONSerialization.data(withJSONObject: ["code": 401, "message": "unauthorized"])
        XCTAssertNil(TraeQuotaFetcher.parseQuotaResponse(body, authData: auth))
    }
}

/// Covers the explicit-scan consent contract (issue #29) for Trae CN: an ordinary refresh
/// must not read `~/Library/Application Support/Trae CN/...` before the user opts in.
final class TraeCnScanConsentTests: XCTestCase {
    private static let persistedIDEQuotasKey = "persisted.ideQuotas"

    /// `QuotaViewModel` persists to `UserDefaults.standard`; keep the developer's data and
    /// run against a known-empty starting state.
    @MainActor
    private func withCleanEnvironment(_ body: () async -> Void) async {
        let savedQuotas = UserDefaults.standard.data(forKey: Self.persistedIDEQuotasKey)
        let savedMode = OperatingModeManager.shared.currentMode
        UserDefaults.standard.removeObject(forKey: Self.persistedIDEQuotasKey)
        // Exercise the direct (non-monitor, non-remote) refresh path deterministically.
        OperatingModeManager.shared.setMode(.localProxy)

        await body()

        OperatingModeManager.shared.setMode(savedMode)
        if let savedQuotas {
            UserDefaults.standard.set(savedQuotas, forKey: Self.persistedIDEQuotasKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.persistedIDEQuotasKey)
        }
    }

    /// A storage.json the fetcher *could* read, so a missing read proves the gate rather
    /// than a missing file. The host is deliberately outside Trae's domains, so the refresh
    /// stops after the local read instead of making a network request.
    private func makeReadableInstall() throws -> TraeScanPathOverrides {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trae-cn-consent-\(UUID().uuidString)", isDirectory: true)
        let globalStorage = root
            .appendingPathComponent("Trae CN.app/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let payload = try JSONSerialization.data(withJSONObject: [
            "token": "cn-access-token",
            "userId": "7412345678901234567",
            "host": "https://blocked.invalid",
            "account": ["email": "consent-fixture@example.cn"]
        ])
        let storageURL = globalStorage.appendingPathComponent("storage.json")
        try JSONSerialization.data(withJSONObject: [
            "iCubeAuthInfo://icube.cloudide": String(data: payload, encoding: .utf8)!
        ]).write(to: storageURL)

        return TraeScanPathOverrides(
            storageJSONPath: storageURL.path,
            appPaths: [root.appendingPathComponent("Trae CN.app").path]
        )
    }

    private func seededQuota() -> ProviderQuotaData {
        ProviderQuotaData(
            models: [ModelQuota(name: "premium-fast", percentage: 50, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// Trae CN is reached by the ungated `refreshAutoDetectedProviders()` sweep, which is
    /// exactly why it needs a gate.
    func testTraeCnIsPartOfTheAutoDetectedRefreshSweep() {
        let autoDetected = AIProvider.allCases.filter { !$0.supportsManualAuth }
        XCTAssertTrue(autoDetected.contains(.traeCn))
    }

    /// The gate itself: nothing imported means no consent has been recorded.
    func testScanGateOpensOnlyForAnImportedAccount() {
        XCTAssertFalse(QuotaViewModel.mayRefreshScanGatedProvider(imported: nil))
        XCTAssertFalse(QuotaViewModel.mayRefreshScanGatedProvider(imported: [:]))
        XCTAssertTrue(
            QuotaViewModel.mayRefreshScanGatedProvider(imported: ["a@example.cn": seededQuota()])
        )
    }

    /// The regression the review asked for: the refresh a general provider refresh performs
    /// for Trae CN must not open storage.json before the user enabled `scanTraeCn`. Once an
    /// explicit scan has imported an account, the same call is allowed to read — that second
    /// half is the control that keeps the first from passing vacuously.
    @MainActor
    func testOrdinaryRefreshDoesNotReadTraeCnStorageBeforeOptIn() async {
        await withCleanEnvironment {
            guard let overrides = try? makeReadableInstall() else {
                return XCTFail("Could not create the Trae CN fixture install")
            }
            let fetcher = TraeQuotaFetcher(variant: .cn, pathOverrides: overrides)
            let viewModel = QuotaViewModel()
            viewModel.setTraeCnFetcherForTesting(fetcher)
            viewModel.providerQuotas = [:]

            // Exactly what `refreshAutoDetectedProviders()` invokes for this provider.
            await viewModel.refreshQuotaForProvider(.traeCn)

            var reads = await fetcher.storageReadAttemptCount
            XCTAssertEqual(
                reads, 0,
                "A refresh must not open ~/Library/Application Support/Trae CN/... before opt-in"
            )
            XCTAssertNil(
                viewModel.providerQuotas[.traeCn],
                "A refresh must not import a Trae CN account without an explicit scan"
            )

            // Control: after an explicit scan imported an account, the gate opens.
            viewModel.providerQuotas[.traeCn] = ["consent-fixture@example.cn": seededQuota()]
            await viewModel.refreshQuotaForProvider(.traeCn)

            reads = await fetcher.storageReadAttemptCount
            XCTAssertEqual(
                reads, 1,
                "Once an explicit scan imported the account, a refresh may update it"
            )
        }
    }
}
