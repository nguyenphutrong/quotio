import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure

actor MonitorOAuthAuthorizer: OAuthAuthorizing {
    typealias KiroIdentityResolver = @Sendable (
        _ accessToken: String,
        _ expiresAt: Date,
        _ clientID: String,
        _ clientSecret: String,
        _ region: String
    ) async -> String?

    private let githubClientID = "Iv1.b507a08c87ecfe98"
    private let vault: any CredentialVault
    private let urlOpener: any URLOpening
    private let callbackTransport: any OAuthCallbackTransport
    private let httpTransport: any OAuthHTTPTransport
    private let resolveKiroIdentity: KiroIdentityResolver
    private var activeAttemptID: OAuthAttemptID?
    private var claudePending: (attemptID: OAuthAttemptID, state: String, verifier: String)?
    private var persistingAttemptID: OAuthAttemptID?
    private var persistenceWaiters: [OAuthAttemptID: [CheckedContinuation<Void, Never>]] = [:]

    init(
        vault: any CredentialVault,
        urlOpener: any URLOpening,
        callbackTransport: any OAuthCallbackTransport,
        httpTransport: any OAuthHTTPTransport,
        resolveKiroIdentity: @escaping KiroIdentityResolver
    ) {
        self.vault = vault
        self.urlOpener = urlOpener
        self.callbackTransport = callbackTransport
        self.httpTransport = httpTransport
        self.resolveKiroIdentity = resolveKiroIdentity
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
        switch provider {
        case .copilot:
            return .completed(try await githubDeviceFlow(attemptID: attemptID, progress: progress))
        case .kiro:
            return .completed(try await kiroDeviceFlow(attemptID: attemptID, progress: progress))
        case .codex, .antigravity:
            return .completed(try await browserPKCEFlow(
                provider: provider,
                attemptID: attemptID,
                progress: progress
            ))
        case .claude:
            return try await beginClaudeLogin(attemptID: attemptID, progress: progress)
        default:
            throw OAuthFlowFailure.unsupportedProvider
        }
    }

    func cancel(attemptID: OAuthAttemptID) async {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        await callbackTransport.stop()
        claudePending = nil
        await waitForPersistence(attemptID: attemptID)
    }

    func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        guard providerID.rawValue == AIProvider.claude.rawValue else {
            throw OAuthFlowFailure.unsupportedProvider
        }
        return try await completeClaudeLogin(code: code, attemptID: attemptID)
    }

    private func beginClaudeLogin(
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        let state = UUID().uuidString
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"),
            URLQueryItem(name: "redirect_uri", value: "https://platform.claude.com/oauth/code/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url,
              await urlOpener.open(url) else {
            throw OAuthFlowFailure.browserOpenFailed
        }
        try ensureActive(attemptID)
        claudePending = (attemptID, state, verifier)
        let prompt = OAuthPrompt(authorizationURL: url)
        await progress(prompt)
        return .awaitingManualCode(prompt: prompt, state: state)
    }

    private func completeClaudeLogin(
        code rawCode: String,
        attemptID: OAuthAttemptID
    ) async throws -> MonitorAccount {
        guard let pending = claudePending,
              pending.attemptID == attemptID,
              activeAttemptID == attemptID else { throw OAuthFlowFailure.expired }
        defer { claudePending = nil }
        let pieces = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = pieces.first, !code.isEmpty else { throw OAuthFlowFailure.invalidResponse }
        if pieces.count == 2, pieces[1] != pending.state { throw OAuthFlowFailure.stateMismatch }
        let tokens = try await postJSON(
            url: "https://platform.claude.com/v1/oauth/token",
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                "redirect_uri": "https://platform.claude.com/oauth/code/callback",
                "code_verifier": pending.verifier,
                "state": pending.state,
            ]
        )
        try ensureActive(attemptID)
        guard let accessToken = tokens["access_token"] as? String else { throw OAuthFlowFailure.invalidResponse }
        let accountJSON = tokens["account"] as? [String: Any]
        let email = accountJSON?["email_address"] as? String ?? "Claude"
        let accountID = accountJSON?["uuid"] as? String
        let account = MonitorAccount.make(
            provider: .claude,
            accountKey: email,
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: nil,
            accountID: accountID,
            expiresAt: (tokens["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) },
            extra: [:]
        )
        try await persist(credential, account: account, attemptID: attemptID)
        activeAttemptID = nil
        return account
    }

    private struct BrowserConfiguration: Sendable {
        let authorizationURL: String
        let tokenURL: String
        let clientID: String
        let clientSecret: String?
        let scopes: String
        let preferredPort: UInt16?
        let callbackPath: String
        let extraAuthorizationValues: [String: String]
    }

    private func browserPKCEFlow(
        provider: AIProvider,
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> MonitorAccount {
        do {
            let config = try browserConfiguration(provider)
            let port = try await callbackTransport.start(preferredPort: config.preferredPort)
            try ensureActive(attemptID)
            let callbackHost = provider == .codex ? "localhost" : "127.0.0.1"
            let redirectURI = "http://\(callbackHost):\(port)\(config.callbackPath)"
            let state = UUID().uuidString
            let verifier = Self.randomURLSafeString(byteCount: 48)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

            guard var components = URLComponents(string: config.authorizationURL) else {
                throw OAuthFlowFailure.invalidResponse
            }
            var values = config.extraAuthorizationValues
            values.merge([
                "client_id": config.clientID,
                "redirect_uri": redirectURI,
                "response_type": "code",
                "scope": config.scopes,
                "state": state,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            ]) { _, new in new }
            components.queryItems = values.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            guard let authorizationURL = components.url else { throw OAuthFlowFailure.invalidResponse }
            guard await urlOpener.open(authorizationURL) else {
                throw OAuthFlowFailure.browserOpenFailed
            }
            try ensureActive(attemptID)
            await progress(OAuthPrompt(authorizationURL: authorizationURL))

            let callback = try await callbackTransport.waitForCallback(timeout: .seconds(180))
            try ensureActive(attemptID)
            let code = try Self.authorizationCode(from: callback, expectedState: state)
            var exchange = [
                "client_id": config.clientID,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI,
            ]
            if let secret = config.clientSecret { exchange["client_secret"] = secret }
            let tokens = try await postForm(url: config.tokenURL, values: exchange)
            try ensureActive(attemptID)
            let account = try await saveBrowserCredential(
                provider: provider,
                tokens: tokens,
                attemptID: attemptID
            )
            await callbackTransport.stop()
            return account
        } catch {
            await callbackTransport.stop()
            throw error
        }
    }

    private func browserConfiguration(_ provider: AIProvider) throws -> BrowserConfiguration {
        switch provider {
        case .codex:
            return BrowserConfiguration(
                authorizationURL: "https://auth.openai.com/oauth/authorize",
                tokenURL: "https://auth.openai.com/oauth/token",
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                clientSecret: nil,
                scopes: "openid profile email offline_access",
                preferredPort: 1455,
                callbackPath: "/auth/callback",
                extraAuthorizationValues: [
                    "codex_cli_simplified_flow": "true",
                    "id_token_add_organizations": "true",
                    "originator": "codex_cli_rs",
                ]
            )
        case .antigravity:
            return googleConfiguration(
                clientID: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
                clientSecret: "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"
            )
        default:
            throw OAuthFlowFailure.unsupportedProvider
        }
    }

    private func googleConfiguration(clientID: String, clientSecret: String) -> BrowserConfiguration {
        BrowserConfiguration(
            authorizationURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token",
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: "openid email profile https://www.googleapis.com/auth/cloud-platform",
            preferredPort: nil,
            callbackPath: "/oauth2callback",
            extraAuthorizationValues: ["access_type": "offline", "prompt": "consent"]
        )
    }

    private func saveBrowserCredential(
        provider: AIProvider,
        tokens: [String: Any],
        attemptID: OAuthAttemptID
    ) async throws -> MonitorAccount {
        guard let accessToken = tokens["access_token"] as? String else { throw OAuthFlowFailure.invalidResponse }
        let idToken = tokens["id_token"] as? String
        let refreshToken = tokens["refresh_token"] as? String
        let expiresIn = (tokens["expires_in"] as? NSNumber)?.doubleValue
        var email = MonitorIdentity.jwtString(idToken, claim: "email")
        var accountID: String?
        if provider == .codex {
            accountID = MonitorIdentity.jwtNestedString(
                idToken,
                namespace: "https://api.openai.com/auth",
                claim: "chatgpt_account_id"
            )
        } else {
            let user = try? await googleUserInfo(accessToken: accessToken)
            try ensureActive(attemptID)
            email = email ?? user?.email
            accountID = user?.id
        }
        let key = email ?? accountID ?? "\(provider.displayName) \(UUID().uuidString.prefix(8))"
        let account = MonitorAccount.make(
            provider: provider,
            accountKey: key,
            displayName: email ?? key,
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            extra: [:]
        )
        try ensureActive(attemptID)
        try await persist(credential, account: account, attemptID: attemptID)
        activeAttemptID = nil
        return account
    }

    private func googleUserInfo(accessToken: String) async throws -> (email: String?, id: String?) {
        let response = try await httpTransport.send(OAuthHTTPRequest(
            url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!,
            headers: ["Authorization": "Bearer \(accessToken)"]
        ))
        guard 200...299 ~= response.statusCode,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw OAuthFlowFailure.invalidResponse
        }
        return (json["email"] as? String, json["id"] as? String)
    }

    private func githubDeviceFlow(
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> MonitorAccount {
        let device = try await postForm(
            url: "https://github.com/login/device/code",
            values: ["client_id": githubClientID, "scope": "read:user"]
        )
        try ensureActive(attemptID)
        guard let deviceCode = device["device_code"] as? String,
              let userCode = device["user_code"] as? String,
              let verification = device["verification_uri"] as? String,
              let verificationURL = URL(string: verification) else {
            throw OAuthFlowFailure.invalidResponse
        }

        _ = await urlOpener.open(verificationURL)
        try ensureActive(attemptID)
        let interval = max(5, device["interval"] as? Int ?? 5)
        let expiresIn = device["expires_in"] as? Int ?? 900
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        await progress(OAuthPrompt(authorizationURL: verificationURL, userCode: userCode))

        var pollInterval = interval
        while Date() < deadline {
            try Task.checkCancellation()
            try ensureActive(attemptID)
            try await Task.sleep(for: .seconds(pollInterval))
            try ensureActive(attemptID)
            let response = try await postForm(
                url: "https://github.com/login/oauth/access_token",
                values: [
                    "client_id": githubClientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            if let token = response["access_token"] as? String {
                return try await saveGitHubCredential(token, attemptID: attemptID)
            }
            switch response["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": pollInterval += 5
            case "expired_token": throw OAuthFlowFailure.expired
            case "access_denied": throw CancellationError()
            default: throw OAuthFlowFailure.invalidResponse
            }
        }
        throw OAuthFlowFailure.expired
    }

    private func saveGitHubCredential(
        _ token: String,
        attemptID: OAuthAttemptID
    ) async throws -> MonitorAccount {
        let response = try await httpTransport.send(OAuthHTTPRequest(
            url: URL(string: "https://api.github.com/user")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/vnd.github+json",
            ]
        ))
        try ensureActive(attemptID)
        guard 200...299 ~= response.statusCode,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let login = json["login"] as? String else {
            throw OAuthFlowFailure.invalidResponse
        }
        let account = MonitorAccount.make(
            provider: .copilot,
            accountKey: login,
            displayName: login,
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: token,
            refreshToken: nil,
            idToken: nil,
            accountID: String(describing: json["id"] ?? login),
            expiresAt: nil,
            extra: [:]
        )
        try ensureActive(attemptID)
        try await persist(credential, account: account, attemptID: attemptID)
        activeAttemptID = nil
        return account
    }

    private func kiroDeviceFlow(
        attemptID: OAuthAttemptID,
        progress: @escaping @concurrent @Sendable (OAuthPrompt) async -> Void
    ) async throws -> MonitorAccount {
        let region = "us-east-1"
        let base = "https://oidc.\(region).amazonaws.com"
        let registration = try await postJSON(
            url: "\(base)/client/register",
            body: [
                "clientName": "Quotio Monitor",
                "clientType": "public",
                "scopes": ["codewhisperer:completions", "codewhisperer:analysis", "codewhisperer:conversations"],
            ]
        )
        try ensureActive(attemptID)
        guard let clientID = registration["clientId"] as? String,
              let clientSecret = registration["clientSecret"] as? String else {
            throw OAuthFlowFailure.invalidResponse
        }
        let device = try await postJSON(
            url: "\(base)/device_authorization",
            body: [
                "clientId": clientID,
                "clientSecret": clientSecret,
                "startUrl": "https://view.awsapps.com/start",
            ]
        )
        try ensureActive(attemptID)
        guard let deviceCode = device["deviceCode"] as? String,
              let userCode = device["userCode"] as? String,
              let verification = (device["verificationUriComplete"] as? String) ?? (device["verificationUri"] as? String),
              let verificationURL = URL(string: verification) else {
            throw OAuthFlowFailure.invalidResponse
        }
        _ = await urlOpener.open(verificationURL)
        try ensureActive(attemptID)
        await progress(OAuthPrompt(authorizationURL: verificationURL, userCode: userCode))
        var interval = max(5, device["interval"] as? Int ?? 5)
        let deadline = Date().addingTimeInterval(TimeInterval(device["expiresIn"] as? Int ?? 600))
        while Date() < deadline {
            try Task.checkCancellation()
            try ensureActive(attemptID)
            try await Task.sleep(for: .seconds(interval))
            try ensureActive(attemptID)
            let result: [String: Any]
            do {
                result = try await postJSON(
                    url: "\(base)/token",
                    body: [
                        "clientId": clientID,
                        "clientSecret": clientSecret,
                        "deviceCode": deviceCode,
                        "grantType": "urn:ietf:params:oauth:grant-type:device_code",
                    ]
                )
            } catch OAuthFlowFailure.provider(let code) where code == "authorization_pending" {
                continue
            } catch OAuthFlowFailure.provider(let code) where code == "slow_down" {
                interval += 5
                continue
            }
            try ensureActive(attemptID)
            guard let accessToken = result["accessToken"] as? String,
                  let refreshToken = result["refreshToken"] as? String else {
                throw OAuthFlowFailure.invalidResponse
            }
            let expiresAt = Date().addingTimeInterval(TimeInterval(result["expiresIn"] as? Int ?? 3600))
            let identity = await resolveKiroIdentity(
                accessToken,
                expiresAt,
                clientID,
                clientSecret,
                region
            )
            try ensureActive(attemptID)
            let accountKey = Self.kiroAccountKey(identity: identity, clientID: clientID)
            let account = MonitorAccount.make(
                provider: .kiro,
                accountKey: accountKey,
                displayName: identity ?? "AWS Builder ID",
                source: .quotioKeychain,
                credentialReference: "keychain",
                canDelete: true
            )
            let credential = MonitorOAuthCredential(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: nil,
                accountID: identity,
                expiresAt: expiresAt,
                extra: [
                    "authMethod": "IdC",
                    "clientId": clientID,
                    "clientSecret": clientSecret,
                    "region": region,
                ]
            )
            try await persist(credential, account: account, attemptID: attemptID)
            activeAttemptID = nil
            return account
        }
        throw OAuthFlowFailure.expired
    }

    nonisolated static func kiroAccountKey(identity: String?, clientID: String) -> String {
        if let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty {
            return identity
        }
        return "AWS Builder ID • " + String(MonitorIdentity.fingerprint(clientID).prefix(8))
    }

    private func postJSON(url: String, body: [String: Any]) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else { throw OAuthFlowFailure.invalidResponse }
        let response = try await httpTransport.send(OAuthHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)
        ))
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw OAuthFlowFailure.invalidResponse
        }
        guard 200...299 ~= response.statusCode else {
            throw OAuthFlowFailure.provider(
                (json["error"] as? String) ?? (json["errorCode"] as? String) ?? "http_\(response.statusCode)"
            )
        }
        return json
    }

    private func postForm(url: String, values: [String: String]) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else { throw OAuthFlowFailure.invalidResponse }
        let body = values
            .map { "\($0.key.monitorFormEncoded)=\($0.value.monitorFormEncoded)" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let response = try await httpTransport.send(OAuthHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            ],
            body: body
        ))
        guard 200...299 ~= response.statusCode,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw OAuthFlowFailure.invalidResponse
        }
        return json
    }

    private func ensureActive(_ attemptID: OAuthAttemptID) throws {
        guard activeAttemptID == attemptID else { throw CancellationError() }
    }

    private func persist(
        _ credential: MonitorOAuthCredential,
        account: MonitorAccount,
        attemptID: OAuthAttemptID
    ) async throws {
        let previousAccount = await vault.accounts().first { $0.id == account.id }
        let previousCredential = await vault.credential(for: account.id)
        try ensureActive(attemptID)
        persistingAttemptID = attemptID

        do {
            try await vault.save(credential, metadata: account)
            guard activeAttemptID == attemptID else {
                if let previousAccount, let previousCredential {
                    try await vault.save(previousCredential, metadata: previousAccount)
                } else {
                    await vault.delete(accountID: account.id)
                }
                finishPersistence(attemptID: attemptID)
                throw CancellationError()
            }
            finishPersistence(attemptID: attemptID)
        } catch {
            finishPersistence(attemptID: attemptID)
            throw error
        }
    }

    private func waitForPersistence(attemptID: OAuthAttemptID) async {
        guard persistingAttemptID == attemptID else { return }
        await withCheckedContinuation { continuation in
            persistenceWaiters[attemptID, default: []].append(continuation)
        }
    }

    private func finishPersistence(attemptID: OAuthAttemptID) {
        guard persistingAttemptID == attemptID else { return }
        persistingAttemptID = nil
        let waiters = persistenceWaiters.removeValue(forKey: attemptID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    nonisolated private static func randomURLSafeString(byteCount: Int) -> String {
        base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    nonisolated static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              values.first(where: { $0.name == "state" })?.value == expectedState else {
            throw OAuthFlowFailure.stateMismatch
        }
        guard let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthFlowFailure.invalidResponse
        }
        return code
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    nonisolated var monitorFormEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
