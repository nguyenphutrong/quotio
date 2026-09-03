import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import QuotioInfrastructure

final class YubiKeySecretVaultTests: XCTestCase {
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

    func testPreflightIgnoresOtherOccupiedSlots() {
        let report = Self.emptySlotReport + """

        Slot 9A (AUTHENTICATION):
          Private key type: ECCP256
        """
        XCTAssertEqual(YubiKeySecretVault.parsePreflight(report).slot9d, .empty)
    }

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

    func testPIVTokenMatchesInstanceIDNotJustDriverID() {
        XCTAssertTrue(YubiKeySecretVault.isPIVToken("com.apple.pivtoken:48B9336CB599456CAC0A442D8EE59713"))
        XCTAssertTrue(YubiKeySecretVault.isPIVToken("com.apple.pivtoken"))
        XCTAssertTrue(YubiKeySecretVault.isPIVToken("com.apple.CryptoTokenKit.pivtoken"))
    }

    func testPIVTokenRejectsSoftwareAndSecureEnclaveKeys() {
        XCTAssertFalse(YubiKeySecretVault.isPIVToken(nil))
        XCTAssertFalse(YubiKeySecretVault.isPIVToken(""))
        XCTAssertFalse(YubiKeySecretVault.isPIVToken("com.apple.setoken"))
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
}
