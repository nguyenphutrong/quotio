//
//  ChecksumVerifier.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Provides SHA256 checksum verification for proxy binary downloads.
//

import Foundation
import CryptoKit

/// Utility for verifying SHA256 checksums of downloaded binaries.
enum ChecksumVerifier {
    
    /// Calculate the SHA256 hash of data.
    /// - Parameter data: The data to hash
    /// - Returns: Lowercase hex string of the SHA256 hash
    static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Verify that data matches an expected SHA256 checksum.
    /// - Parameters:
    ///   - data: The data to verify
    ///   - expected: The expected SHA256 hash (lowercase hex string)
    /// - Returns: `true` if the checksum matches
    static func verify(data: Data, expected: String) -> Bool {
        let actual = sha256(of: data)
        return actual.lowercased() == expected.lowercased()
    }
    
    /// Verify data and throw an error if checksum doesn't match.
    /// - Parameters:
    ///   - data: The data to verify
    ///   - expected: The expected SHA256 hash (lowercase hex string)
    /// - Throws: `ProxyUpgradeError.checksumMismatch` if verification fails
    static func verifyOrThrow(data: Data, expected: String) throws {
        let actual = sha256(of: data)
        guard actual.lowercased() == expected.lowercased() else {
            throw ProxyUpgradeError.checksumMismatch(expected: expected, actual: actual)
        }
    }
    
    /// Calculate SHA256 hash of a file using streaming to avoid loading entire file into memory.
    /// - Parameter fileURL: URL to the file
    /// - Returns: Lowercase hex string of the SHA256 hash
    /// - Throws: If file cannot be read
    static func sha256(ofFile fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 64 * 1024 // 64KB chunks
        
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty {
                return false
            }
            hasher.update(data: data)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Verify that a file matches an expected SHA256 checksum.
    /// - Parameters:
    ///   - fileURL: URL to the file to verify
    ///   - expected: The expected SHA256 hash (lowercase hex string)
    /// - Returns: `true` if the checksum matches
    /// - Throws: If file cannot be read
    static func verify(fileURL: URL, expected: String) throws -> Bool {
        let actual = try sha256(ofFile: fileURL)
        return actual.lowercased() == expected.lowercased()
    }
}
