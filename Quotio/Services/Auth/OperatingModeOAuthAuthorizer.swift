import QuotioApplication
import QuotioDomain

actor OperatingModeOAuthAuthorizer: OAuthAuthorizing {
    typealias MonitorModeProvider = @Sendable () async -> Bool

    private enum Route {
        case monitor
        case localProxy
    }

    private let monitor: any OAuthAuthorizing
    private let localProxy: any OAuthAuthorizing
    private let isMonitorMode: MonitorModeProvider
    private var routes: [OAuthAttemptID: Route] = [:]

    init(
        monitor: any OAuthAuthorizing,
        localProxy: any OAuthAuthorizing,
        isMonitorMode: @escaping MonitorModeProvider
    ) {
        self.monitor = monitor
        self.localProxy = localProxy
        self.isMonitorMode = isMonitorMode
    }

    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        let route: Route = await isMonitorMode() ? .monitor : .localProxy
        routes[attemptID] = route
        let outcome = try await authorizer(for: route).begin(
            request: request,
            attemptID: attemptID,
            progress: progress
        )
        if case .completed = outcome {
            routes[attemptID] = nil
        }
        return outcome
    }

    func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        guard let route = routes[attemptID] else { throw OAuthFlowFailure.expired }
        let account = try await authorizer(for: route).completeManualCode(
            code,
            providerID: providerID,
            attemptID: attemptID
        )
        routes[attemptID] = nil
        return account
    }

    func cancel(attemptID: OAuthAttemptID) async {
        guard let route = routes.removeValue(forKey: attemptID) else { return }
        await authorizer(for: route).cancel(attemptID: attemptID)
    }

    private func authorizer(for route: Route) -> any OAuthAuthorizing {
        switch route {
        case .monitor: monitor
        case .localProxy: localProxy
        }
    }
}
