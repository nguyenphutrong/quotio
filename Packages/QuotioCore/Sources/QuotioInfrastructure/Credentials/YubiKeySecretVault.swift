// Legacy YubiKey envelopes are retained only for one-way credential migration.
import CryptoKit
import Foundation
import LocalAuthentication
@preconcurrency import Security

nonisolated enum YubiKeySecretVault {
    private struct AvailableIdentity: @unchecked Sendable {
        let fingerprint: String
        let identity: SecIdentity
    }
    private struct Envelope: Decodable {
        let version: Int
        let wrappedKey: Data
        let sealedSecret: Data
    }
    typealias ReadResult = ProtectedCredentialReadResult
    private static var fileManager: FileManager { .default }
    private static var selectedIdentity: AvailableIdentity? {
        guard let fingerprint = UserDefaults.standard.string(forKey: "yubikeyPIVVaultFingerprint") else { return nil }
        return availableIdentityRecords().first { $0.fingerprint == fingerprint }
    }
    static func isPIVToken(_ tokenID: String?) -> Bool {
        guard let tokenID else { return false }
        let driver = tokenID.prefix { $0 != ":" }
        return driver == "com.apple.pivtoken" || driver == "com.apple.CryptoTokenKit.pivtoken"
    }

    static func availableIdentityQuery() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassIdentity,
            kSecAttrAccessGroup as String: kSecAttrAccessGroupToken,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private static func availableIdentityRecords() -> [AvailableIdentity] {
        let query = availableIdentityQuery()
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard isPIVToken(item[kSecAttrTokenID as String] as? String),
                  let reference = item[kSecValueRef as String] else { return nil }
            let cfReference = reference as CFTypeRef
            guard CFGetTypeID(cfReference) == SecIdentityGetTypeID() else { return nil }
            let identity = reference as! SecIdentity
            guard let certificate = certificate(for: identity),
                  let publicKey = SecCertificateCopyKey(certificate),
                  SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionOAEPSHA256),
                  let external = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
            let fingerprint = SHA256.hash(data: external).map { String(format: "%02x", $0) }.joined()
            return AvailableIdentity(
                fingerprint: fingerprint,
                identity: identity
            )
        }
    }

    static func readResult(service: String, account: String) -> ReadResult {
        let envelopeURL = url(service: service, account: account)
        guard fileManager.fileExists(atPath: envelopeURL.path) else { return .absent }
        guard let attributes = try? envelopeURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (attributes.fileSize ?? Int.max) <= 1_048_576,
              let identity = selectedIdentity,
              let envelopeData = try? Data(contentsOf: envelopeURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
              envelope.version == 1,
              let privateKey = privateKey(for: identity.identity) else { return .unreadable }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, envelope.wrappedKey as CFData, &error) as Data? else { return .unreadable }
        do {
            let key = SymmetricKey(data: keyData)
            return .success(try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealedSecret), using: key))
        } catch {
            return .unreadable
        }
    }

    private static func certificate(for identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess ? certificate : nil
    }

    private static func privateKey(for identity: SecIdentity) -> SecKey? {
        var key: SecKey?
        return SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess ? key : nil
    }

    private static func url(service: String, account: String) -> URL {
        let identifier = SHA256.hash(data: Data("\(service)\u{0}\(account)".utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(identifier).appendingPathExtension("qsv")
    }

    private static var directory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio", isDirectory: true)
            .appendingPathComponent("YubiKeyVault", isDirectory: true)
    }

}

public actor LegacyYubiKeyCredentialReader: LegacyProtectedCredentialReading {
    public init() {}
    public func read(service: String, account: String) -> ProtectedCredentialReadResult {
        YubiKeySecretVault.readResult(service: service, account: account)
    }
}
