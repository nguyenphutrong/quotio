import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class OAuthScreenModel {
    public private(set) var state: OAuthFlowState = .idle

    @ObservationIgnored private let controller: OAuthFlowController
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var successHandler: (@MainActor @Sendable () async -> Void)?

    public init(controller: OAuthFlowController) {
        self.controller = controller
        observe()
    }

    deinit {
        observationTask?.cancel()
    }

    public func setSuccessHandler(_ handler: (@MainActor @Sendable () async -> Void)?) {
        successHandler = handler
    }

    public func start(_ request: OAuthAuthorizationRequest) async {
        await controller.start(request)
    }

    public func completeManualCode(_ code: String) async {
        await controller.completeManualCode(code)
    }

    public func cancel() async {
        await controller.cancel()
    }

    public func reset() async {
        await controller.cancel()
    }

    public func shutdown() async {
        observationTask?.cancel()
        observationTask = nil
        await controller.shutdown()
        state = .idle
    }

    private func observe() {
        let controller = controller
        observationTask = Task { [weak self] in
            let states = await controller.states()
            for await nextState in states {
                guard !Task.isCancelled, let self else { return }
                let wasSuccessful = if case .succeeded = state { true } else { false }
                state = nextState
                if !wasSuccessful, case .succeeded = nextState {
                    await successHandler?()
                }
            }
        }
    }
}
