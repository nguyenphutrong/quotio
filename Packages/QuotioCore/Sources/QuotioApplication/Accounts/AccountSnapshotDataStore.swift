import Foundation

/// Opaque persistence boundary for the legacy Monitor snapshot payload.
/// Quota models and JSON mapping remain in their current slice until Phase 7.
public protocol AccountSnapshotDataStore: Sendable {
    func read() async throws -> Data?
    func write(_ data: Data) async throws
}
