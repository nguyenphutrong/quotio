import Foundation
import QuotioApplication
import QuotioDomain

public actor LocalProxyOAuthAuthorizer: OAuthAuthorizing {
    public typealias RuntimeProvider = @MainActor @Sendable () -> LocalProxyOAuthRuntime
    public typealias KiroTokenRefresher = @Sendable () async -> Int

    private let runtime: RuntimeProvider
    private let authenticator: any ProxyCLIAuthenticating
    private let authFiles: any AuthFileRepository
    private let urlOpener: any URLOpening
    private let refreshKiroTokens: KiroTokenRefresher
    private let managementAPIFactory: any ProxyManagementAPIFactory
    private var activeAttemptID: OAuthAttemptID?
    private var activeClient: (any ProxyManagementAPI)?

    public init(
        runtime: @escaping RuntimeProvider,
        authenticator: any ProxyCLIAuthenticating,
        authFiles: any AuthFileRepository,
        urlOpener: any URLOpening,
        managementAPIFactory: any ProxyManagementAPIFactory,
        refreshKiroTokens: @escaping KiroTokenRefresher
    ) {
        self.runtime = runtime
        self.authenticator = authenticator
        self.authFiles = authFiles
        self.urlOpener = urlOpener
        self.managementAPIFactory = managementAPIFactory
        self.refreshKiroTokens = refreshKiroTokens
    }

    public func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        guard let provider = QuotaProvider(rawValue: request.providerID.rawValue) else {
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

    public func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        throw OAuthFlowFailure.unsupportedProvider
    }

    public func cancel(attemptID: OAuthAttemptID) async {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        await activeClient?.invalidate()
        activeClient = nil
        await authenticator.terminate()
    }

    private func runManagementFlow(
        provider: QuotaProvider,
        automaticallyOpensBrowser: Bool,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> Account {
        guard let connection = await runtime().management else {
            throw OAuthFlowFailure.provider("Proxy not running. Please start the proxy first.")
        }
        let client = managementAPIFactory.makeManagementAPI(
            connection: connection
        )
        activeClient = client
        do {
            guard let managementProvider = ProxyManagementOAuthProvider(provider) else {
                throw OAuthFlowFailure.unsupportedProvider
            }
            let response = try await client.startOAuth(for: managementProvider)
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
        let command: ProxyCLIAuthCommand = switch method {
        case .kiroAWSDeviceCode: .kiroAWSLogin
        case .kiroAWSBrowser: .kiroAWSAuthCode
        case .kiroImport: .kiroImport
        default: .kiroGoogleLogin
        }
        if command == .kiroImport {
            let result = try await runAuthCommand(command)
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
        provider: QuotaProvider,
        command: ProxyCLIAuthCommand,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> Account {
        let initialCount = await authFileCount(for: provider)
        let result = try await runAuthCommand(command)
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

    private func authFileCount(for provider: QuotaProvider) async -> Int {
        let providerValues = provider == .copilot
            ? Set(["github-copilot", "copilot"])
            : Set([provider.rawValue])
        return await authFiles.scanAllAuthFiles().count {
            providerValues.contains($0.providerID.rawValue)
        }
    }

    private func runAuthCommand(_ command: ProxyCLIAuthCommand) async throws -> ProxyCLIAuthResult {
        guard let cli = await runtime().cli else {
            throw OAuthFlowFailure.provider("CLIProxyAPI binary not found")
        }
        return await authenticator.run(command, runtime: cli)
    }

    private func completedAccount(_ provider: QuotaProvider) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: Self.accountName(provider),
            source: .legacyCLIProxy,
            credentialMetadata: RedactedCredentialMetadata(kind: .authFile)
        )
    }

    private func ensureActive(_ attemptID: OAuthAttemptID) throws {
        guard activeAttemptID == attemptID else { throw CancellationError() }
    }

    private nonisolated static func accountName(_ provider: QuotaProvider) -> String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .qwen: "Qwen Code"
        case .iflow: "iFlow"
        case .antigravity: "Antigravity"
        case .vertex: "Vertex AI"
        case .kiro: "Kiro"
        case .copilot: "GitHub Copilot"
        case .cursor: "Cursor"
        case .factoryDroid: "Factory Droid"
        case .devin: "Devin"
        case .grok: "Grok"
        case .openRouter: "OpenRouter"
        case .amp: "Amp"
        case .trae: "Trae"
        case .glm: "Z.ai"
        case .warp: "Warp"
        case .clinePass: "ClinePass"
        }
    }
}

private extension ProxyManagementOAuthProvider {
    nonisolated init?(_ provider: QuotaProvider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .qwen: self = .qwen
        case .iflow: self = .iflow
        case .antigravity: self = .antigravity
        default: return nil
        }
    }
}
