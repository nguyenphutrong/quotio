import QuotioDomain

public protocol TunnelControlling: Sendable {
    func detectInstallation() async -> CloudflaredInstallation
    func start(
        port: UInt16,
        onURLDetected: @escaping @Sendable (String) -> Void
    ) async throws
    func stop() async
    func isRunning() async -> Bool
    func cleanupOrphans() async
}

public protocol TunnelRemoteAccessControlling: Sendable {
    func setRemoteAccessEnabled(_ enabled: Bool) async
}

public protocol TunnelLifecycleControlling: Sendable {
    var snapshot: CloudflareTunnelSnapshot { get async }

    func states() async -> AsyncStream<CloudflareTunnelSnapshot>
    func refreshInstallation() async
    func start(port: UInt16) async
    func stop() async
    func toggle(port: UInt16) async
    func shutdown() async
    func cleanupOrphans() async
}
