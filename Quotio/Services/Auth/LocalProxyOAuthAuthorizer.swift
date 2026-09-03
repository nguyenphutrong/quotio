import Foundation
import QuotioApplication
import QuotioDomain
import QuotioPresentation

actor LocalProxyOAuthAuthorizer: OAuthAuthorizing {
    typealias KiroTokenRefresher = @Sendable () async -> Int

    private let proxy: ProxyScreenModel
    private let authService: LegacyProxyAuthService
    private let authFiles: any AuthFileRepository
    private let urlOpener: any URLOpening
    private let refreshKiroTokens: KiroTokenRefresher
    private var activeAttemptID: OAuthAttemptID?
    private var activeClient: ManagementAPIClient?

    init(
        proxy: ProxyScreenModel,
        authService: LegacyProxyAuthService,
        authFiles: any AuthFileRepository,
        urlOpener: any URLOpening,
        refreshKiroTokens: @escaping KiroTokenRefresher
    ) {
        self.proxy = proxy
        self.authService = authService
        self.authFiles = authFiles
        self.urlOpener = urlOpener
        self.refreshKiroTokens = refreshKiroTokens
    }

    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        guard let provider = AIProvider(rawValue: request.providerID.rawValue) else {
            throw OAuthFlowFailure.unsupportedProvider
        }
        activeAttemptID = attemptID

        let account: Account
        switch provider {
        case .copilot:
            account = try await runCLIFlow(
                provider: provider,
                command: .copilotLogin,
                attemptID: attemptID,
                progress: progress
            )
        case .kiro:
            account = try await runKiroFlow(
                method: request.method,
                attemptID: attemptID,
                progress: progress
            )
        default:
            account = try await runManagementFlow(
                provider: provider,
                automaticallyOpensBrowser: request.automaticallyOpensBrowser,
                attemptID: attemptID,
                progress: progress
            )
        }
        try ensureActive(attemptID)
        activeAttemptID = nil
        return .completed(account)
    }

    func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        throw OAuthFlowFailure.unsupportedProvider
    }

    func cancel(attemptID: OAuthAttemptID) async {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        await activeClient?.invalidate()
        activeClient = nil
        await authService.terminate()
    }

    private func runManagementFlow(
        provider: AIProvider,
        automaticallyOpensBrowser: Bool,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> Account {
        let connection = await MainActor.run {
            guard proxy.proxyStatus.running else { return nil as (String, String)? }
            return (proxy.managementURL, proxy.managementKey)
        }
        guard let connection else {
            throw OAuthFlowFailure.provider("Proxy not running. Please start the proxy first.")
        }
        let client = ManagementAPIClient(baseURL: connection.0, authKey: connection.1)
        activeClient = client
        do {
            let response = try await client.getOAuthURL(for: provider)
            try ensureActive(attemptID)
            guard response.status == "ok",
                  let urlString = response.url,
                  let state = response.state,
                  let url = URL(string: urlString) else {
                throw OAuthFlowFailure.provider(response.error ?? "The OAuth provider returned an invalid response.")
            }
            if automaticallyOpensBrowser {
                guard await urlOpener.open(url) else { throw OAuthFlowFailure.browserOpenFailed }
            }
            await progress(OAuthPrompt(authorizationURL: url))

            for _ in 0..<60 {
                try Task.checkCancellation()
                try ensureActive(attemptID)
                try await Task.sleep(for: .seconds(2))
                try ensureActive(attemptID)
                do {
                    let status = try await client.pollOAuthStatus(state: state)
                    switch status.status {
                    case "ok":
                        await client.invalidate()
                        activeClient = nil
                        return completedAccount(provider)
                    case "error":
                        throw OAuthFlowFailure.provider(status.error ?? "The OAuth provider rejected the request.")
                    default:
                        continue
                    }
                } catch let failure as OAuthFlowFailure {
                    throw failure
                } catch {
                    continue
                }
            }
            throw OAuthFlowFailure.expired
        } catch {
            await client.invalidate()
            activeClient = nil
            throw error
        }
    }

    private func runKiroFlow(
        method: OAuthAuthorizationMethod,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> Account {
        let command: AuthCommand = switch method {
        case .kiroAWSDeviceCode: .kiroAWSLogin
        case .kiroAWSBrowser: .kiroAWSAuthCode
        case .kiroImport: .kiroImport
        default: .kiroGoogleLogin
        }
        if command == .kiroImport {
            let result = await authService.run(command)
            try ensureActive(attemptID)
            guard result.success else { throw OAuthFlowFailure.provider(result.message) }
            await progress(OAuthPrompt(message: "Importing quotas..."))
            try await Task.sleep(for: .milliseconds(1_500))
            try ensureActive(attemptID)
            _ = await refreshKiroTokens()
            return completedAccount(.kiro)
        }
        return try await runCLIFlow(
            provider: .kiro,
            command: command,
            attemptID: attemptID,
            progress: progress
        )
    }

    private func runCLIFlow(
        provider: AIProvider,
        command: AuthCommand,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> Account {
        let initialCount = await authFileCount(for: provider)
        let result = await authService.run(command)
        try ensureActive(attemptID)
        guard result.success else { throw OAuthFlowFailure.provider(result.message) }
        await progress(OAuthPrompt(userCode: result.deviceCode, message: result.message))

        for _ in 0..<90 {
            try Task.checkCancellation()
            try ensureActive(attemptID)
            try await Task.sleep(for: .seconds(2))
            try ensureActive(attemptID)
            guard await authFileCount(for: provider) > initialCount else { continue }
            if provider == .kiro {
                _ = await refreshKiroTokens()
            }
            return completedAccount(provider)
        }
        throw OAuthFlowFailure.expired
    }

    private func authFileCount(for provider: AIProvider) async -> Int {
        let providerValues = provider == .copilot
            ? Set(["github-copilot", "copilot"])
            : Set([provider.rawValue])
        return await authFiles.scanAllAuthFiles().count {
            providerValues.contains($0.providerID.rawValue)
        }
    }

    private func completedAccount(_ provider: AIProvider) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: provider.displayName,
            source: .legacyCLIProxy,
            credentialMetadata: RedactedCredentialMetadata(kind: .authFile)
        )
    }

    private func ensureActive(_ attemptID: OAuthAttemptID) throws {
        guard activeAttemptID == attemptID else { throw CancellationError() }
    }
}
