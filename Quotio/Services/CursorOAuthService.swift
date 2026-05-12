//
//  CursorOAuthService.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Implements Cursor's browser-based PKCE login flow so users can add multiple
//  Cursor accounts to Quotio without having to sign in/out of the Cursor IDE
//  itself. The protocol is reverse-engineered (Cursor has no public auth API):
//
//    1. Generate a PKCE verifier (43 random bytes, base64url) and challenge
//       (sha256 of the verifier string, base64url).
//    2. Generate a random UUID.
//    3. Open https://www.cursor.com/loginDeepControl?challenge=&uuid=&mode=login
//       in the user's default browser.
//    4. Poll https://api2.cursor.sh/auth/poll?uuid=&verifier= every few seconds.
//       Returns 200 with { accessToken, refreshToken?, authId } on completion.
//
//  References: https://github.com/JiuZ-Chn/Cursor-To-OpenAI/blob/main/src/tool/cursorLogin.js
//

import Foundation
import CryptoKit
import AppKit

/// One concluded login attempt.
nonisolated struct CursorOAuthResult: Sendable {
    let accessToken: String
    let refreshToken: String?
    let authId: String?
    /// Best-effort email pulled from the JWT payload (may be nil).
    let email: String?
}

enum CursorOAuthError: LocalizedError {
    case cancelled
    case timedOut
    case network(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in cancelled."
        case .timedOut: return "Timed out waiting for browser login."
        case .network(let msg): return "Network error: \(msg)"
        }
    }
}

actor CursorOAuthService {
    /// In-progress flow. Surfaced so the UI can show the URL while polling.
    struct InFlightFlow: Sendable {
        let uuid: String
        let verifier: String
        let challenge: String
        let loginURL: URL
    }

    private let pollEndpoint = "https://api2.cursor.sh/auth/poll"
    private let loginEndpoint = "https://www.cursor.com/loginDeepControl"

    // Cursor's auth poll endpoint rejects requests that don't look like the IDE.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Cursor/0.48.6 Chrome/132.0.6834.210 Electron/34.3.4 Safari/537.36"

    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
        self.session = URLSession(configuration: config)
    }

    /// Begin a new flow. Returns the parameters the UI needs to render +
    /// (optionally) opens the browser for the user.
    func startFlow(openBrowser: Bool = true) -> InFlightFlow {
        let verifier = Self.makeVerifier()
        let challenge = Self.makeChallenge(from: verifier)
        let uuid = UUID().uuidString.lowercased()

        var components = URLComponents(string: loginEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login")
        ]
        let url = components.url!

        if openBrowser {
            // NSWorkspace.open is main-actor isolated; jump there.
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }

        return InFlightFlow(uuid: uuid, verifier: verifier, challenge: challenge, loginURL: url)
    }

    /// Poll until login completes, the deadline is hit, or the task is cancelled.
    /// `intervalSeconds` is how long to wait between attempts.
    func waitForCompletion(
        flow: InFlightFlow,
        timeoutSeconds: TimeInterval = 300,
        intervalSeconds: TimeInterval = 3
    ) async throws -> CursorOAuthResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            try Task.checkCancellation()

            if let result = try await pollOnce(uuid: flow.uuid, verifier: flow.verifier) {
                return result
            }

            try await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
        }

        throw CursorOAuthError.timedOut
    }

    // MARK: - Polling

    private struct PollResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let authId: String?
    }

    private func pollOnce(uuid: String, verifier: String) async throws -> CursorOAuthResult? {
        var components = URLComponents(string: pollEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "verifier", value: verifier)
        ]
        guard let url = components.url else {
            throw CursorOAuthError.network("invalid poll URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Transient network blips should not abort the whole flow.
            return nil
        }

        guard let http = response as? HTTPURLResponse else { return nil }

        // Anything other than 200 = "not ready yet".
        guard http.statusCode == 200 else { return nil }

        let decoded = (try? JSONDecoder().decode(PollResponse.self, from: data))

        guard let accessToken = decoded?.accessToken, !accessToken.isEmpty else {
            return nil
        }

        let email = Self.emailFromJWT(accessToken)

        return CursorOAuthResult(
            accessToken: accessToken,
            refreshToken: decoded?.refreshToken,
            authId: decoded?.authId,
            email: email
        )
    }

    // MARK: - PKCE helpers

    nonisolated private static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 43)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    nonisolated private static func makeChallenge(from verifier: String) -> String {
        // Cursor hashes the *string form* of the verifier (matching the JS
        // reference implementation), not the decoded random bytes.
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    nonisolated private static func base64URLEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode the JWT payload (no signature verification — we only need claims
    /// for display). Returns `email` if present, otherwise `sub` (user id).
    nonisolated private static func emailFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4.
        let pad = (4 - (b64.count % 4)) % 4
        b64.append(String(repeating: "=", count: pad))

        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let email = json["email"] as? String, !email.isEmpty {
            return email
        }
        // Fall back to subject (user id like `user_01XXX`).
        return json["sub"] as? String
    }
}
