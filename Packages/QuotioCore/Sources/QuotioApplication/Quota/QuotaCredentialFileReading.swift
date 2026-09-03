import Foundation

/// Narrow filesystem port used by quota adapters that discover provider-owned credentials.
public protocol QuotaCredentialFileReading: Sendable {
    func read(path: String) async -> Data?
}
