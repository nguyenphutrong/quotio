//
//  AntigravityRefreshTokenImportService.swift
//  Quotio
//
//  Imports an Antigravity account from a Google OAuth refresh token.
//  Exchanges the refresh token for an access token and writes a compatible
//  auth file to ~/.cli-proxy-api that CLIProxyAPI and the quota fetcher can read.
//

import Foundation

// MARK: - Import Result

struct AntigravityImportResult: Sendable {
    let email: String
    let filePath: String
}

// MARK: - Service

actor AntigravityRefreshTokenImportService {

    // Google OAuth constants (same as AntigravityQuotaFetcher)
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let clientSecret = "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"

    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case emptyEmail
        case emptyToken
        case invalidToken
        case tokenExchangeFailed(Int)
        case networkError(String)
        case fileWriteError(String)
        case accountAlreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .emptyEmail:
                return "antigravity.import.error.emptyEmail".localizedStatic()
            case .emptyToken:
                return "antigravity.import.error.emptyToken".localizedStatic()
            case .invalidToken:
                return "antigravity.import.error.invalidToken".localizedStatic()
            case .tokenExchangeFailed(let code):
                return String(format: "antigravity.import.error.network".localizedStatic(), "HTTP \(code)")
            case .networkError(let msg):
                return String(format: "antigravity.import.error.network".localizedStatic(), msg)
            case .fileWriteError(let msg):
                return String(format: "antigravity.import.error.fileWrite".localizedStatic(), msg)
            case .accountAlreadyExists(let email):
                return String(format: "antigravity.import.error.accountExists".localizedStatic(), email)
            }
        }
    }

    // MARK: - Public API

    /// Import an Antigravity account using a refresh token.
    ///
    /// - Parameters:
    ///   - email: Google account email address (used to name the auth file).
    ///   - refreshToken: Valid Google OAuth refresh token.
    ///   - authDir: Directory where auth files are stored (default `~/.cli-proxy-api`).
    ///   - overwrite: When `true`, overwrites an existing auth file for the same email.
    /// - Returns: Import result containing email and file path on success.
    func importAccount(
        email: String,
        refreshToken: String,
        authDir: String = "~/.cli-proxy-api",
        overwrite: Bool = false
    ) async throws -> AntigravityImportResult {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty else { throw ImportError.emptyEmail }
        guard !trimmedToken.isEmpty else { throw ImportError.emptyToken }

        let expandedDir = NSString(string: authDir).expandingTildeInPath
        let fileName = "antigravity-\(trimmedEmail).json"
        let filePath = (expandedDir as NSString).appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: filePath) && !overwrite {
            throw ImportError.accountAlreadyExists(trimmedEmail)
        }

        // Exchange refresh token → access token
        let (accessToken, expiresIn) = try await exchangeRefreshToken(trimmedToken)

        // Build expiry timestamp
        let now = Date()
        let expiryDate = now.addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current

        let json: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": trimmedToken,
            "email": trimmedEmail,
            "expired": formatter.string(from: expiryDate),
            "expires_in": expiresIn,
            "timestamp": Int64(now.timeIntervalSince1970 * 1000),
            "type": "antigravity"
        ]

        try FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            throw ImportError.fileWriteError("Failed to serialize auth data")
        }

        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            throw ImportError.fileWriteError(error.localizedDescription)
        }

        return AntigravityImportResult(email: trimmedEmail, filePath: filePath)
    }

    // MARK: - Private

    private func exchangeRefreshToken(_ refreshToken: String) async throws -> (accessToken: String, expiresIn: Int) {
        guard let url = URL(string: tokenURL) else {
            throw ImportError.networkError("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImportError.networkError("Invalid server response")
            }

            if httpResponse.statusCode == 400 {
                throw ImportError.invalidToken
            }

            guard 200...299 ~= httpResponse.statusCode else {
                throw ImportError.tokenExchangeFailed(httpResponse.statusCode)
            }

            struct TokenResponse: Decodable {
                let accessToken: String
                let expiresIn: Int
                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case expiresIn = "expires_in"
                }
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            return (tokenResponse.accessToken, tokenResponse.expiresIn)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.networkError(error.localizedDescription)
        }
    }
}
