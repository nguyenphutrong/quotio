//
//  TraeAuthEnvelope.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Decodes the value Trae stores under "iCubeAuthInfo://icube.cloudide" in
//  .../User/globalStorage/storage.json.
//

import CommonCrypto
import CryptoKit
import Foundation

/// Decoder for Trae's `iCubeAuthInfo://icube.cloudide` storage value.
///
/// Current Trae desktop clients — both the international edition and Trae CN — do not
/// write that value as plaintext JSON. It is a Base64 envelope:
///
///     header(6) ‖ randomKey(32) ‖ AES-128-CBC( SHA512(payload) ‖ payload )
///
/// with the AES material derived as `SHA512( SHA512(randomKey) ‖ secret )`, taking
/// `key = derived[0..<16]`, `iv = derived[16..<32]`, PKCS#7 padding. The decrypted
/// plaintext starts with a SHA-512 digest of the JSON payload that follows it, which is
/// verified before the payload is parsed.
///
/// **Provenance.** ByteDance does not document this format. It is reproduced here from two
/// independent open-source implementations that agree byte-for-byte:
///
/// - `koi128bit/WorkBuddy-Switch` — `Sources/OpenUsage/TraeSupport.swift` (Swift)
/// - `luckymiaow/trae-mate` — `src-tauri/src/trae_auth.rs` (Rust)
///
/// trae-mate stores `secret` obfuscated as two 64-byte halves that are XORed together at
/// runtime; the result equals `staticSecret` below, which is how the two sources were
/// cross-checked. `TraeAuthEnvelopeTests` re-derives the constant from trae-mate's halves
/// so the cross-check is enforced by the test suite rather than by this comment.
///
/// Plaintext JSON is still accepted (checked first), so a storage.json written by an older
/// client keeps working.
nonisolated enum TraeAuthEnvelope {
    enum DecodeError: Error, Equatable {
        /// The value is neither plaintext JSON nor a well-formed Base64 envelope.
        case malformedEnvelope
        /// AES-128-CBC decryption failed (wrong key material or corrupt ciphertext).
        case decryptionFailed
        /// The SHA-512 prefix does not match the payload it precedes.
        case integrityCheckFailed
        /// The decoded payload is not a JSON object.
        case invalidPayload
    }

    /// Envelope magic prefix.
    static let header = Data([116, 99, 5, 16, 0, 0])

    /// Key-derivation secret. See the provenance note above.
    private static let staticSecret = Data([
        0x4d, 0xd4, 0xc2, 0xe6, 0xb8, 0x31, 0x62, 0x09, 0x0e, 0x52, 0xb3, 0xc7, 0xa6, 0x73, 0x3b, 0xa4,
        0x1c, 0xb2, 0x46, 0x2b, 0x82, 0x9a, 0xb5, 0x8a, 0x19, 0x6b, 0x39, 0xdb, 0x57, 0x17, 0x75, 0x24,
        0xf4, 0x9b, 0xaf, 0x7f, 0x08, 0xe8, 0xd6, 0x8d, 0x26, 0xa7, 0x2e, 0x37, 0xc1, 0xa9, 0x5a, 0x2f,
        0x1f, 0x05, 0xa5, 0x18, 0x92, 0xae, 0xf2, 0x94, 0x97, 0x32, 0xb6, 0x2a, 0x38, 0xaa, 0xdd, 0x58
    ])

    private static let randomKeyLength = 32
    private static let digestLength = 64

    /// Decode a storage value into the auth JSON object it carries.
    ///
    /// Accepts either plaintext JSON (legacy clients) or the encrypted envelope written by
    /// current clients.
    static func decodeAuthInfo(_ value: String) throws -> [String: Any] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DecodeError.malformedEnvelope }

        let payload: Data
        if trimmed.hasPrefix("{") {
            guard let plain = trimmed.data(using: .utf8) else { throw DecodeError.malformedEnvelope }
            payload = plain
        } else {
            payload = try decrypt(trimmed)
        }

        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DecodeError.invalidPayload
        }
        return object
    }

    /// Decrypt an envelope and return the verified JSON payload bytes.
    static func decrypt(_ encoded: String) throws -> Data {
        guard let blob = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw DecodeError.malformedEnvelope
        }
        let minimumLength = header.count + randomKeyLength + kCCBlockSizeAES128
        guard blob.count >= minimumLength, blob.prefix(header.count) == header else {
            throw DecodeError.malformedEnvelope
        }

        let keyStart = blob.startIndex + header.count
        let ciphertextStart = keyStart + randomKeyLength
        let randomKey = Data(blob[keyStart..<ciphertextStart])
        let ciphertext = Data(blob[ciphertextStart...])

        let material = deriveMaterial(randomKey: randomKey)
        let plain = try decryptAES128CBC(
            ciphertext,
            key: Data(material.prefix(16)),
            iv: Data(material.dropFirst(16).prefix(16))
        )

        guard plain.count >= digestLength else { throw DecodeError.malformedEnvelope }
        let expectedDigest = Data(plain.prefix(digestLength))
        let payload = Data(plain.dropFirst(digestLength))
        let actualDigest = Data(SHA512.hash(data: payload))
        guard constantTimeEquals(expectedDigest, actualDigest) else {
            throw DecodeError.integrityCheckFailed
        }
        return payload
    }

    /// `SHA512( SHA512(randomKey) ‖ secret )` — the first 32 bytes are the AES key and IV.
    static func deriveMaterial(randomKey: Data) -> Data {
        var seed = Data(SHA512.hash(data: randomKey))
        seed.append(staticSecret)
        return Data(SHA512.hash(data: seed))
    }

    private static func decryptAES128CBC(_ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
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
        guard status == kCCSuccess else { throw DecodeError.decryptionFailed }
        output.count = outputLength
        return output
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
