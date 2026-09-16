import Foundation
import QuotioApplication
import QuotioDomain

public actor QuotioCLIOAuthAuthorizer: OAuthAuthorizing {
    private let backend: QuotioCLIBackend
    private let urlOpener: any URLOpening
    private let callbackTransport: any OAuthCallbackTransport
    private var sessions: [OAuthAttemptID: String] = [:]

    public init(
        backend: QuotioCLIBackend,
        urlOpener: any URLOpening,
        callbackTransport: any OAuthCallbackTransport
    ) {
        self.backend = backend
        self.urlOpener = urlOpener
        self.callbackTransport = callbackTransport
    }

    public func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        guard let provider = QuotaProvider(rawValue: request.providerID.rawValue),
              [.codex, .claude, .copilot].contains(provider),
              let cliProvider = QuotioCLIProviderMap.cli(provider) else {
            throw OAuthFlowFailure.unsupportedProvider
        }
        if provider == .codex {
            _ = try await callbackTransport.start(preferredPort: 1455)
        }
        do {
            let session = try await backend.beginOAuth(provider: cliProvider)
            sessions[attemptID] = session.id
            guard let url = URL(string: session.url) else { throw OAuthFlowFailure.invalidResponse }
            let prompt = OAuthPrompt(authorizationURL: url, userCode: session.userCode)
            await progress(prompt)
            if request.automaticallyOpensBrowser, !(await urlOpener.open(url)) {
                throw OAuthFlowFailure.browserOpenFailed
            }
            switch session.workflow {
            case "manual_code":
                return .awaitingManualCode(prompt: prompt, state: session.id)
            case "browser_callback":
                let callback = try await callbackTransport.waitForCallback(timeout: .seconds(180))
                _ = try await backend.completeOAuth(id: session.id, callbackURL: callback.absoluteString)
                await callbackTransport.stop()
                return .completed(try await completedAccount(sessionID: session.id, provider: provider))
            case "device_code":
                return .completed(try await completedAccount(sessionID: session.id, provider: provider))
            default:
                throw OAuthFlowFailure.invalidResponse
            }
        } catch let failure as OAuthFlowFailure {
            await callbackTransport.stop()
            throw failure
        } catch {
            await callbackTransport.stop()
            throw OAuthFlowFailure.provider(Self.errorCode(error))
        }
    }

    public func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        guard providerID.rawValue == QuotaProvider.claude.rawValue,
              let sessionID = sessions[attemptID] else {
            throw OAuthFlowFailure.expired
        }
        do {
            _ = try await backend.completeOAuth(id: sessionID, code: code)
            return try await completedAccount(sessionID: sessionID, provider: .claude)
        } catch {
            throw OAuthFlowFailure.provider(Self.errorCode(error))
        }
    }

    public func cancel(attemptID: OAuthAttemptID) async {
        if let sessionID = sessions.removeValue(forKey: attemptID) {
            await backend.cancelOAuth(id: sessionID)
        }
        await callbackTransport.stop()
    }

    private func completedAccount(sessionID: String, provider: QuotaProvider) async throws -> Account {
        let deadline = ContinuousClock.now + .seconds(180)
        var session = try await backend.oauthSession(id: sessionID)
        while ["waiting", "processing"].contains(session.status) {
            guard ContinuousClock.now < deadline else { throw OAuthFlowFailure.expired }
            try await Task.sleep(for: .milliseconds(500))
            session = try await backend.oauthSession(id: sessionID)
        }
        guard session.status == "completed", let accountID = session.accountId else {
            throw OAuthFlowFailure.provider(session.errorCode ?? session.status)
        }
        sessions = sessions.filter { $0.value != sessionID }
        if let account = await backend.accounts().first(where: { $0.id == accountID }) {
            return account
        }
        return Account(
            identity: AccountIdentity(
                id: accountID,
                providerID: AccountProviderID(rawValue: provider.rawValue),
                accountKey: provider.rawValue
            ),
            displayName: provider.rawValue,
            source: .quotioKeychain,
            capabilities: [.disable, .delete],
            status: .ready,
            credentialMetadata: RedactedCredentialMetadata(kind: .oauth)
        )
    }

    private static func errorCode(_ error: Error) -> String {
        if case let QuotioCLIBackendError.response(_, code) = error { return code }
        if error is QuotioCLIBackendError { return "quotio_backend_unavailable" }
        return "oauth_failed"
    }
}
