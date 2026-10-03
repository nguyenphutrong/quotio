import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import QuotioInfrastructure

final class YubiKeySecretVaultTests: XCTestCase {
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
