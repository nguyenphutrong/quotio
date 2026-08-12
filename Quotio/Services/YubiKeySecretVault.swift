//
//  YubiKeySecretVault.swift
//  Quotio
//
//  Stores Quotio-owned secrets as ciphertext and requires the selected PIV
//  hardware key to unwrap the encryption key.
//

import CryptoKit
import Foundation
import IOKit
@preconcurrency import Security

nonisolated struct YubiKeyPIVIdentity: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let name: String
    let fingerprint: String

    fileprivate let identity: SecIdentity

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

nonisolated struct YubiKeyPIVDevice: Identifiable, Hashable, Sendable {
    let serial: String
    let name: String
    var id: String { serial }
}

/// A PIV-backed vault for secrets owned by Quotio. Only encrypted envelopes
/// are written to disk; private-key operations remain on the selected token.
nonisolated enum YubiKeySecretVault {
    private static let selectedFingerprintKey = "yubikeyPIVVaultFingerprint"
    private static var fileManager: FileManager { .default }
    private static let lock = NSLock()

    private struct Envelope: Codable {
        let version: Int
        let wrappedKey: Data
        let sealedSecret: Data
    }

    static var isEnabled: Bool {
        UserDefaults.standard.string(forKey: selectedFingerprintKey) != nil
    }

    static var selectedIdentity: YubiKeyPIVIdentity? {
        guard let fingerprint = UserDefaults.standard.string(forKey: selectedFingerprintKey) else { return nil }
        return availableIdentities().first { $0.fingerprint == fingerprint }
    }

    /// Detects attached YubiKeys independently of PIV provisioning. This keeps
    /// the Settings panel discoverable for a new key that has no certificate yet.
    static func isYubiKeyConnected() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let vendorIDProperty = IORegistryEntryCreateCFProperty(
                device, "idVendor" as CFString, kCFAllocatorDefault, 0
            )
            let vendorID = vendorIDProperty?.takeRetainedValue() as? NSNumber
            let vendorNameProperty = IORegistryEntryCreateCFProperty(
                device, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0
            )
            let vendorName = vendorNameProperty?.takeRetainedValue() as? String
            if vendorID?.intValue == 0x1050 || vendorName?.localizedCaseInsensitiveContains("Yubico") == true {
                return true
            }
        }
        return false
    }

    static func provisionableDevices() -> [YubiKeyPIVDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ykman")
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let listing = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
            return listing.split(separator: "\n").compactMap { line in
                guard line.contains("CCID"), let serialRange = line.range(of: "Serial: ") else { return nil }
                let serial = line[serialRange.upperBound...].trimmingCharacters(in: .whitespaces)
                guard serial.allSatisfy(\.isNumber) else { return nil }
                return YubiKeyPIVDevice(serial: serial, name: String(line[..<serialRange.lowerBound]).trimmingCharacters(in: .whitespaces))
            }
        } catch { return [] }
    }

    /// Starts an interactive, local YubiKey Manager session.  Credentials are
    /// requested by ykman in Terminal and are never passed through Quotio.
    @discardableResult
    static func beginProvisioning(_ device: YubiKeyPIVDevice) -> Bool {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-piv-\(device.serial)-\(UUID().uuidString).zsh")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        ykman_bin=/opt/homebrew/bin/ykman
        test -x \"$ykman_bin\" || ykman_bin=ykman
        public_key=$(mktemp -t quotio-piv-public-key)
        trap 'rm -f \"$public_key\"' EXIT
        echo 'Quotio will create a dedicated RSA-2048 PIV key in slot 9d.'
        echo 'YubiKey Manager may ask you to authorise PIV administration.'
        \"$ykman_bin\" --device \(device.serial) piv access change-management-key --protect --generate
        \"$ykman_bin\" --device \(device.serial) piv keys generate --algorithm RSA2048 --pin-policy always 9d \"$public_key\"
        \"$ykman_bin\" --device \(device.serial) piv certificates generate --subject 'CN=Quotio Secret Vault' --valid-days 3650 9d \"$public_key\"
        echo 'Quotio PIV identity created. Return to Quotio and choose Refresh YubiKeys.'
        read '?Press Return to close this window.'
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            let terminal = Process()
            terminal.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            terminal.arguments = ["-e", "tell application \"Terminal\" to activate", "-e", "tell application \"Terminal\" to do script \"/bin/zsh '\(scriptURL.path)'\""]
            try terminal.run()
            return true
        } catch { return false }
    }

    /// Returns RSA PIV identities currently available through macOS securityd.
    static func availableIdentities() -> [YubiKeyPIVIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return [] }

        return identities.compactMap { identity in
            guard let privateKey = privateKey(for: identity),
                  let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
                  // macOS exposes PIV cards through this built-in token driver.
                  attributes[kSecAttrTokenID as String] as? String == "com.apple.CryptoTokenKit.pivtoken",
                  let publicKey = SecKeyCopyPublicKey(privateKey),
                  SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionOAEPSHA256),
                  let external = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { return nil }
            let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "PIV key"
            let fingerprint = SHA256.hash(data: external).map { String(format: "%02x", $0) }.joined()
            return YubiKeyPIVIdentity(id: fingerprint, name: summary, fingerprint: fingerprint, identity: identity)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Changing a token after secrets have been written would strand those
    /// envelopes. Keep the association immutable until an explicit migration
    /// workflow exists.
    @discardableResult
    static func select(_ identity: YubiKeyPIVIdentity) -> Bool {
        if let current = UserDefaults.standard.string(forKey: selectedFingerprintKey),
           current != identity.fingerprint,
           hasStoredSecrets {
            return false
        }
        UserDefaults.standard.set(identity.fingerprint, forKey: selectedFingerprintKey)
        return true
    }

    static func save(_ data: Data, service: String, account: String) -> Bool {
        guard let identity = selectedIdentity, let publicKey = publicKey(for: identity.identity) else { return false }
        do {
            let contentKey = SymmetricKey(size: .bits256)
            let keyData = contentKey.withUnsafeBytes { Data($0) }
            var error: Unmanaged<CFError>?
            guard let wrappedKey = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, keyData as CFData, &error) as Data? else { return false }
            let sealed = try AES.GCM.seal(data, using: contentKey).combined!
            let envelope = try JSONEncoder().encode(Envelope(version: 1, wrappedKey: wrappedKey, sealedSecret: sealed))
            try write(envelope, service: service, account: account)
            return true
        } catch {
            Log.keychain("YubiKey vault save failed: \(error.localizedDescription)")
            return false
        }
    }

    static func read(service: String, account: String) -> Data? {
        guard let identity = selectedIdentity,
              let envelopeData = try? Data(contentsOf: url(service: service, account: account)),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
              envelope.version == 1, let privateKey = privateKey(for: identity.identity) else { return nil }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, envelope.wrappedKey as CFData, &error) as Data? else { return nil }
        do {
            let key = SymmetricKey(data: keyData)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealedSecret), using: key)
        } catch {
            Log.keychain("YubiKey vault decrypt failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func contains(service: String, account: String) -> Bool {
        fileManager.fileExists(atPath: url(service: service, account: account).path)
    }

    static func delete(service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: url(service: service, account: account))
    }

    private static func publicKey(for identity: SecIdentity) -> SecKey? {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { return nil }
        return SecKeyCopyPublicKey(key)
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

    private static var hasStoredSecrets: Bool {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.isEmpty == false
    }

    private static func write(_ data: Data, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(service: service, account: account), options: .atomic)
    }
}
