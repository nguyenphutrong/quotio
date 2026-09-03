import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class TunnelScreenModel {
    public private(set) var tunnelState: CloudflareTunnelSnapshot {
        didSet {
            guard oldValue != tunnelState else { return }
            didChangeHandler?(tunnelState)
        }
    }

    @ObservationIgnored private let controller: any TunnelLifecycleControlling
    @ObservationIgnored private let failureMessage: @MainActor (TunnelFailure) -> String
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var didChangeHandler: (@MainActor (CloudflareTunnelSnapshot) -> Void)?

    public init(
        controller: any TunnelLifecycleControlling,
        initialState: CloudflareTunnelSnapshot = CloudflareTunnelSnapshot(),
        failureMessage: @escaping @MainActor (TunnelFailure) -> String = TunnelScreenModel.defaultMessage
    ) {
        self.controller = controller
        self.tunnelState = initialState
        self.failureMessage = failureMessage
        observe()
    }

    deinit {
        observationTask?.cancel()
    }

    public var installation: CloudflaredInstallation { tunnelState.installation }
    public var errorMessage: String? { tunnelState.failure.map(failureMessage) }

    public func setDidChangeHandler(
        _ handler: (@MainActor (CloudflareTunnelSnapshot) -> Void)?
    ) {
        didChangeHandler = handler
    }

    public func refreshInstallation() async {
        await controller.refreshInstallation()
        tunnelState = await controller.snapshot
    }

    public func startTunnel(port: UInt16) async {
        await controller.start(port: port)
        tunnelState = await controller.snapshot
    }

    public func stopTunnel() async {
        await controller.stop()
        tunnelState = await controller.snapshot
    }

    public func toggle(port: UInt16) async {
        await controller.toggle(port: port)
        tunnelState = await controller.snapshot
    }

    public func shutdown() async {
        observationTask?.cancel()
        observationTask = nil
        await controller.shutdown()
        tunnelState = await controller.snapshot
    }

    public func cleanupOrphans() async {
        await controller.cleanupOrphans()
    }

    private func observe() {
        let controller = controller
        observationTask = Task { [weak self] in
            let states = await controller.states()
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                self.tunnelState = state
            }
        }
    }

    public static func defaultMessage(for failure: TunnelFailure) -> String {
        switch failure {
        case .notInstalled:
            "Cloudflared is not installed"
        case .alreadyRunning:
            "Tunnel is already running"
        case .startFailed(let reason):
            "Failed to start tunnel: \(reason)"
        case .unexpectedExit:
            "Tunnel exited unexpectedly"
        case .startTimeout:
            "Tunnel start timed out"
        }
    }
}
