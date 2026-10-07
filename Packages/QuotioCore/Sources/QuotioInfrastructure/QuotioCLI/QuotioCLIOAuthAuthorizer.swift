import QuotioHostClient
import Foundation
import QuotioApplication
import QuotioDomain

public actor QuotioCLIOAuthAuthorizer: OAuthAuthorizing {
    private let backend: QuotioCLIBackend
    private let urlOpener: any URLOpening
    private var sessions: [OAuthAttemptID: QuotioCLIOAuthSession] = [:]

    public init(
        backend: QuotioCLIBackend,
        urlOpener: any URLOpening
    ) {
        self.backend = backend
        self.urlOpener = urlOpener
    }

    public func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        guard let provider = QuotaProvider(rawValue: request.providerID.rawValue) else {
            throw OAuthFlowFailure.unsupportedProvider
        }
        if request.githubHost != nil, provider != .copilot {
            throw OAuthFlowFailure.unsupportedProvider
        }
        let cliProvider = provider.rawValue
        do {
            let session = try await backend.beginOAuth(
                provider: cliProvider,
                githubHost: request.githubHost?.value
            )
            sessions[attemptID] = session
            try Task.checkCancellation()
            guard session.provider == cliProvider, let url = URL(string: session.url),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw OAuthFlowFailure.invalidResponse
            }
            let prompt = OAuthPrompt(authorizationURL: url, userCode: session.userCode)
            await progress(prompt)
            if request.automaticallyOpensBrowser, !(await urlOpener.open(url)) {
                throw OAuthFlowFailure.browserOpenFailed
            }
            switch session.workflow {
            case "manual_code":
                return .awaitingManualCode(prompt: prompt, state: session.id)
            case "browser_callback", "device_code":
                return .completed(try await completedAccount(sessionID: session.id, provider: provider))
            default:
                throw OAuthFlowFailure.invalidResponse
            }
        } catch let failure as OAuthFlowFailure {
            await cancel(attemptID: attemptID)
            throw failure
        } catch {
            await cancel(attemptID: attemptID)
            throw OAuthFlowFailure.provider(Self.errorCode(error))
        }
    }

    public func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        guard let session = sessions[attemptID], session.workflow == "manual_code",
              let provider = QuotaProvider(rawValue: providerID.rawValue),
              provider.rawValue == session.provider else {
            throw OAuthFlowFailure.expired
        }
        do {
            _ = try await backend.completeOAuth(id: session.id, code: code)
            return try await completedAccount(sessionID: session.id, provider: provider)
        } catch {
            throw OAuthFlowFailure.provider(Self.errorCode(error))
        }
    }

    public func cancel(attemptID: OAuthAttemptID) async {
        if let session = sessions.removeValue(forKey: attemptID) {
            let backend = backend
            // Cleanup must still reach the host when the authorization task was cancelled.
            await Task { await backend.cancelOAuth(id: session.id) }.value
        }
    }

    private func completedAccount(sessionID: String, provider: QuotaProvider) async throws -> Account {
        var session = try await backend.oauthSession(id: sessionID)
        while ["waiting", "processing"].contains(session.status) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(500))
            session = try await backend.oauthSession(id: sessionID)
        }
        if session.status == "expired" { throw OAuthFlowFailure.expired }
        guard session.status == "completed", let accountID = session.accountId else {
            throw OAuthFlowFailure.provider(session.errorCode ?? session.status)
        }
        let account = try await backend.resolvedAccount(id: accountID)
        guard account.providerID.rawValue == provider.rawValue else { throw OAuthFlowFailure.invalidResponse }
        sessions = sessions.filter { $0.value.id != sessionID }
        return account
    }

    private static func errorCode(_ error: Error) -> String {
        if case let QuotioHostClientError.response(_, code) = error { return code }
        if error is QuotioHostClientError { return "quotio_backend_unavailable" }
        return "oauth_failed"
    }
}
