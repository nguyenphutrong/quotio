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
import LocalAuthentication
import os
import QuotioApplication
import QuotioDomain
@preconcurrency import Security

/// A PIV-backed vault for secrets owned by Quotio. Only encrypted envelopes
/// are written to disk; private-key operations remain on the selected token.
nonisolated enum YubiKeySecretVault {
    /// Certificate subject Quotio provisions, and the name macOS then reports
    /// for the identity.
    static let identityName = "Quotio Secret Vault"

    private static let selectedFingerprintKey = "yubikeyPIVVaultFingerprint"
    private static var fileManager: FileManager { .default }
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.nguyenphutrong.Quotio", category: "YubiKeyVault")

    private struct AvailableIdentity: @unchecked Sendable {
        let value: YubiKeyPIVIdentity
        let identity: SecIdentity
    }

    private struct Envelope: Codable {
        let version: Int
        let wrappedKey: Data
        let sealedSecret: Data
    }

    enum ReadResult: Equatable {
        case absent
        case unreadable
        case success(Data)
    }

    static func shouldMigrateLegacy(_ result: ReadResult) -> Bool {
        if case .absent = result { return true }
        return false
    }

    static var isEnabled: Bool {
        selectedFingerprint != nil
    }

    /// The fingerprint Quotio is configured to use, whether or not that key is
    /// currently plugged in. Settings needs this to tell "not configured" apart
    /// from "configured but absent".
    static var selectedFingerprint: String? {
        UserDefaults.standard.string(forKey: selectedFingerprintKey)
    }

    private static var selectedIdentity: AvailableIdentity? {
        guard let fingerprint = selectedFingerprint else { return nil }
        return availableIdentityRecords().first { $0.value.fingerprint == fingerprint }
    }

    /// Resolves the configured key against an already-loaded identity list, so
    /// callers that just enumerated identities do not enumerate them twice.
    static func identity(matching identities: [YubiKeyPIVIdentity]) -> YubiKeyPIVIdentity? {
        guard let fingerprint = selectedFingerprint else { return nil }
        return identities.first { $0.fingerprint == fingerprint }
    }

    /// Number of secrets currently sealed to the configured key.
    static var protectedSecretCount: Int {
        envelopeURLs.count
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
        guard case let .completed(status, listing) = runYkman(["list"], timeout: 20), status == 0 else { return [] }
        return listing.split(separator: "\n").compactMap { line in
            guard line.contains("CCID"), let serialRange = line.range(of: "Serial: ") else { return nil }
            let serial = line[serialRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard serial.allSatisfy(\.isNumber) else { return nil }
            return YubiKeyPIVDevice(serial: serial, name: String(line[..<serialRange.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Reports what provisioning would overwrite, without changing anything.
    static func preflight(_ device: YubiKeyPIVDevice) -> Result<YubiKeyPIVPreflight, YubiKeyProvisioningError> {
        switch runYkman(["--device", device.serial, "piv", "info"], timeout: 30) {
        case .toolMissing:
            return .failure(.toolMissing)
        case .timedOut:
            return .failure(.timedOut)
        case let .launchFailed(message):
            return .failure(.deviceUnavailable(message))
        case let .completed(status, output):
            guard status == 0 else { return .failure(.deviceUnavailable(condensed(output))) }
            return .success(parsePreflight(output))
        }
    }

    static func parsePreflight(_ report: String) -> YubiKeyPIVPreflight {
        let lines = report.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let listsSlot9d = lines.contains { $0.lowercased().hasPrefix("slot 9d") }
        let pinTries = lines.first { $0.hasPrefix("PIN tries remaining:") }
            .map { $0.replacingOccurrences(of: "PIN tries remaining:", with: "").trimmingCharacters(in: .whitespaces) }

        // `piv info` lists a slot when it holds a key or a certificate, but it can
        // only enumerate keys through key metadata, which arrived in PIV 5.3. On
        // older firmware a bare private key is invisible here, so "not listed" is
        // not proof of "empty" and must never be reported as such.
        let slot9d: YubiKeyPIVSlotState
        if listsSlot9d {
            slot9d = .occupied
        } else if let version = pivVersion(in: lines), version >= (5, 3, 0) {
            slot9d = .empty
        } else {
            slot9d = .unknown
        }

        return YubiKeyPIVPreflight(
            slot9d: slot9d,
            managementKeyProtected: lines.contains {
                $0.hasPrefix("Management key is stored on the YubiKey")
                    || $0.hasPrefix("Management key is derived from PIN")
            },
            usesDefaultManagementKey: lines.contains { $0.contains("Using default Management key") },
            pinTriesRemaining: pinTries,
            report: report.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Creates the Quotio PIV identity in slot 9d. Destructive: the caller must
    /// have confirmed the outcome described by `preflight`.
    static func provision(
        device: YubiKeyPIVDevice,
        preflight: YubiKeyPIVPreflight,
        pin: String,
        managementKey: String?
    ) -> Result<Void, YubiKeyProvisioningError> {
        let publicKeyURL = fileManager.temporaryDirectory
            .appendingPathComponent("quotio-piv-\(UUID().uuidString).pem")
        defer { try? fileManager.removeItem(at: publicKeyURL) }

        // ykman prompts for the current management key only when it is not already
        // protected by the PIN. Writing a line it never reads would shift the PIN
        // onto the following prompt and burn a PIN attempt, so the prompt count is
        // derived from the state we just inspected.
        var credentials: [String] = []
        if !preflight.managementKeyProtected {
            // Blank selects ykman's documented default management key.
            credentials.append(managementKey?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        credentials.append(pin)

        let steps: [(step: String, arguments: [String], input: [String])] = [
            (
                "piv access change-management-key",
                ["--device", device.serial, "piv", "access", "change-management-key", "--protect", "--generate"],
                credentials
            ),
            // The management key is protected by the PIN from here on, so the
            // remaining steps authenticate with the PIN alone.
            (
                "piv keys generate",
                ["--device", device.serial, "piv", "keys", "generate",
                 "--algorithm", "RSA2048", "--pin-policy", "always", "9d", publicKeyURL.path],
                [pin]
            ),
            (
                "piv certificates generate",
                ["--device", device.serial, "piv", "certificates", "generate",
                 "--subject", "CN=\(identityName)", "--valid-days", "3650", "9d", publicKeyURL.path],
                [pin]
            ),
        ]

        for step in steps {
            if case let .failure(error) = run(step.arguments, input: step.input, step: step.step) {
                return .failure(error)
            }
        }
        return .success(())
    }

    /// Returns RSA PIV identities currently available through macOS securityd.
    /// Whether a key's `kSecAttrTokenID` identifies it as living on a PIV card.
    ///
    /// macOS reports the token *instance*, not the driver bundle: the driver ID
    /// with the card's UUID appended, `com.apple.pivtoken:48B9336C…`. Comparing
    /// against a bare driver ID therefore never matches, which silently hides
    /// every PIV identity. Both spellings of the driver are accepted; software
    /// keys (no token) and Secure Enclave keys (`com.apple.setoken`) are not.
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

    static func availableIdentities() -> [YubiKeyPIVIdentity] {
        availableIdentityRecords().map(\.value)
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
            let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "PIV key"
            let fingerprint = SHA256.hash(data: external).map { String(format: "%02x", $0) }.joined()
            return AvailableIdentity(
                value: YubiKeyPIVIdentity(id: fingerprint, name: summary, fingerprint: fingerprint),
                identity: identity
            )
        }
        .sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
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
            logger.warning("YubiKey vault save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func read(service: String, account: String) -> Data? {
        guard case let .success(data) = readResult(service: service, account: account) else { return nil }
        return data
    }

    static func readResult(service: String, account: String) -> ReadResult {
        let envelopeURL = url(service: service, account: account)
        guard fileManager.fileExists(atPath: envelopeURL.path) else { return .absent }
        guard let identity = selectedIdentity,
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
            logger.warning("YubiKey vault decrypt failed: \(error.localizedDescription, privacy: .public)")
            return .unreadable
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
        guard let certificate = certificate(for: identity) else { return nil }
        return SecCertificateCopyKey(certificate)
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

    private static var envelopeURLs: [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "qsv" }
    }

    private static var hasStoredSecrets: Bool {
        !envelopeURLs.isEmpty
    }

    private static func write(_ data: Data, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(service: service, account: account), options: .atomic)
    }

    // MARK: - ykman

    private enum CommandOutcome {
        case completed(status: Int32, output: String)
        case timedOut
        case toolMissing
        case launchFailed(String)
    }

    /// Collects a child process's output from a background thread. Draining has
    /// to run alongside the wait below: ykman writes its prompts while it is
    /// still running, and a full pipe buffer would deadlock both sides.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static var executableURL: URL? {
        ["/opt/homebrew/bin/ykman", "/usr/local/bin/ykman"]
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Runs ykman headlessly. Secrets are written to the child's stdin rather
    /// than passed as arguments, which would expose them to `ps` for every
    /// process running as this user.
    ///
    /// ykman prompts through `click`, which reads hidden input from the
    /// controlling terminal and falls back to stdin when there is none. A
    /// bundled app has no controlling terminal, so the pipe below is what the
    /// prompts read; the timeout covers the case where something else grabs
    /// them, so a stuck prompt surfaces as an error instead of a hang.
    private static func runYkman(
        _ arguments: [String],
        input: [String] = [],
        timeout: TimeInterval = 120
    ) -> CommandOutcome {
        guard let executableURL else { return .toolMissing }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }

        if !input.isEmpty {
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data((input.joined(separator: "\n") + "\n").utf8))
        }
        try? inputPipe.fileHandleForWriting.close()

        let buffer = OutputBuffer()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            buffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            _ = drained.wait(timeout: .now() + 5)
            return .timedOut
        }
        _ = drained.wait(timeout: .now() + 5)
        return .completed(status: process.terminationStatus, output: buffer.text)
    }

    private static func run(
        _ arguments: [String],
        input: [String],
        step: String
    ) -> Result<Void, YubiKeyProvisioningError> {
        switch runYkman(arguments, input: input) {
        case .toolMissing:
            return .failure(.toolMissing)
        case .timedOut:
            return .failure(.timedOut)
        case let .launchFailed(message):
            return .failure(.stepFailed("\(step): \(message)"))
        case let .completed(status, output):
            guard status != 0 else { return .success(()) }
            if output.contains("PIN is blocked") { return .failure(.pinBlocked) }
            if output.contains("PIN verification failed") {
                return .failure(.pinRejected(triesRemaining: pinTriesLeft(in: output)))
            }
            if output.contains("Authentication with management key failed") {
                return .failure(.managementKeyRejected)
            }
            logger.warning("YubiKey provisioning step failed (\(step, privacy: .public)): \(condensed(output), privacy: .public)")
            return .failure(.stepFailed("\(step): \(condensed(output))"))
        }
    }

    private static func pinTriesLeft(in output: String) -> Int? {
        guard let range = output.range(of: #"(\d+) tries left"#, options: .regularExpression) else { return nil }
        return Int(output[range].prefix { $0.isNumber })
    }

    private static func pivVersion(in lines: [String]) -> (Int, Int, Int)? {
        guard let line = lines.first(where: { $0.hasPrefix("PIV version:") }) else { return nil }
        let parts = line.replacingOccurrences(of: "PIV version:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ".")
            .compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// Trims ykman output down to what is worth showing a user: the prompt
    /// echoes and the no-terminal warning carry no diagnostic value.
    private static func condensed(_ output: String) -> String {
        let noise = ["Enter PIN", "Enter a management key", "Enter the current management key",
                     "GetPassWarning", "Password input may be echoed"]
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains { line.contains($0) } }
        return lines.suffix(3).joined(separator: " ")
    }
}

public actor YubiKeyVaultAdapter: YubiKeyVaultManaging, ProtectedCredentialDataStoring {
    public nonisolated var identityName: String { YubiKeySecretVault.identityName }

    public init() {}

    public func snapshot() -> YubiKeyVaultSnapshot {
        let identities = YubiKeySecretVault.availableIdentities()
        return YubiKeyVaultSnapshot(
            isConnected: YubiKeySecretVault.isYubiKeyConnected(),
            devices: YubiKeySecretVault.provisionableDevices(),
            identities: identities,
            selectedIdentity: YubiKeySecretVault.identity(matching: identities),
            selectedFingerprint: YubiKeySecretVault.selectedFingerprint,
            protectedSecretCount: YubiKeySecretVault.protectedSecretCount
        )
    }

    public func select(_ identity: YubiKeyPIVIdentity) -> Bool {
        YubiKeySecretVault.select(identity)
    }

    public func preflight(
        _ device: YubiKeyPIVDevice
    ) -> Result<YubiKeyPIVPreflight, YubiKeyProvisioningError> {
        YubiKeySecretVault.preflight(device)
    }

    public func provision(
        device: YubiKeyPIVDevice,
        preflight: YubiKeyPIVPreflight,
        pin: String,
        managementKey: String?
    ) -> Result<Void, YubiKeyProvisioningError> {
        YubiKeySecretVault.provision(
            device: device,
            preflight: preflight,
            pin: pin,
            managementKey: managementKey
        )
    }

    public var isEnabled: Bool {
        get async { YubiKeySecretVault.isEnabled }
    }

    public func read(service: String, account: String) -> ProtectedCredentialReadResult {
        switch YubiKeySecretVault.readResult(service: service, account: account) {
        case .absent: .absent
        case .unreadable: .unreadable
        case .success(let data): .success(data)
        }
    }

    public func save(_ data: Data, service: String, account: String) -> Bool {
        YubiKeySecretVault.save(data, service: service, account: account)
    }

    public func delete(service: String, account: String) {
        YubiKeySecretVault.delete(service: service, account: account)
    }
}
