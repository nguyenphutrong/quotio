import Foundation
import QuotioApplication
import QuotioDomain

public actor FileAuthFileRepository: AuthFileRepository {
    private let fileManager: FileManager
    private let authDirectory: URL
    private let awsSSOCacheDirectory: URL

    public init(
        authDirectory: URL? = nil,
        awsSSOCacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.authDirectory = authDirectory ?? URL(
            fileURLWithPath: NSString(string: "~/.cli-proxy-api").expandingTildeInPath,
            isDirectory: true
        )
        self.awsSSOCacheDirectory = awsSSOCacheDirectory ?? URL(
            fileURLWithPath: NSString(string: "~/.aws/sso/cache").expandingTildeInPath,
            isDirectory: true
        )
    }

    public func scanAllAuthFiles() -> [AuthFileDescriptor] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  isRegularNonSymbolicFile(url) else { return nil }
            return parseAuthFileJSON(at: url) ?? parseAuthFileName(url)
        }
    }

    public func readCredential(from file: AuthFileDescriptor) -> AuthFileCredential? {
        let url = URL(fileURLWithPath: file.filePath)
        guard isRegularNonSymbolicFile(url),
              let data = fileManager.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch file.providerID.rawValue {
        case "antigravity":
            guard let accessToken = json["access_token"] as? String else { return nil }
            return AuthFileCredential(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresAt: json["expiry"] as? String ?? json["expires_at"] as? String,
                clientID: nil,
                clientSecret: nil,
                authMethod: nil,
                extras: nil
            )
        case "codex":
            guard let token = json["access_token"] as? String ?? json["api_key"] as? String else {
                return nil
            }
            return credential(accessToken: token)
        case "github-copilot", "copilot":
            guard let token = json["access_token"] as? String ?? json["oauth_token"] as? String else {
                return nil
            }
            return credential(accessToken: token)
        case "claude":
            guard let token = json["session_key"] as? String ?? json["access_token"] as? String else {
                return nil
            }
            return credential(accessToken: token)
        case "kiro":
            return readKiroCredential(json: json, fileURL: url)
        default:
            guard let token = json["access_token"] as? String ?? json["token"] as? String else {
                return nil
            }
            return credential(accessToken: token)
        }
    }

    public func uploadAuthFile(name: String, content: Data) throws {
        let fileURL = try authFileURL(for: name)
        try validateAuthFileContent(content)
        try SecureAtomicFileWriter.write(content, to: fileURL)
    }

    public func readAuthFileForImport(from url: URL) throws -> Data {
        try validateAuthFileName(url.lastPathComponent)
        guard isRegularNonSymbolicFile(url) else {
            throw AuthFileRepositoryError.symbolicLinkRefused
        }
        do {
            let content = try Data(contentsOf: url)
            try validateAuthFileContent(content)
            return content
        } catch let error as AuthFileRepositoryError {
            throw error
        } catch {
            throw AuthFileRepositoryError.readFailed(error.localizedDescription)
        }
    }

    public func writeDownloadedAuthFile(_ content: Data, to url: URL) throws {
        do {
            try SecureAtomicFileWriter.write(content, to: url)
        } catch let error as AuthFileRepositoryError {
            throw error
        } catch {
            throw AuthFileRepositoryError.saveFailed(error.localizedDescription)
        }
    }

    public func downloadAuthFile(name: String) throws -> Data {
        let fileURL = try authFileURL(for: name)
        guard isRegularNonSymbolicFile(fileURL) else {
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AuthFileRepositoryError.symbolicLinkRefused
            }
            throw AuthFileRepositoryError.fileNotFound(name)
        }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw AuthFileRepositoryError.readFailed(error.localizedDescription)
        }
    }

    private func parseAuthFileJSON(at url: URL) -> AuthFileDescriptor? {
        guard let data = fileManager.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let providerID = Self.providerID(for: type) else { return nil }

        var email = json["email"] as? String
        var login = json["login"] as? String
        var legacyIdentityKeys: [String] = []
        if providerID.rawValue == "github-copilot" {
            let rawLogin = json["login"] as? String
            login = Self.firstNonBlank(json["username"] as? String, rawLogin)
            if let rawLogin = Self.nonBlank(rawLogin), rawLogin != login {
                legacyIdentityKeys.append(rawLogin)
            }
        }
        if providerID.rawValue == "kiro", Self.nonBlank(email) == nil,
           let authProvider = Self.nonBlank(json["provider"] as? String) {
            email = "Kiro (\(authProvider))"
        }

        let expired: Date?
        if let value = json["expired"] as? String {
            expired = Self.parseISO8601Date(value)
        } else if let value = json["expired"] as? NSNumber {
            expired = Date(timeIntervalSince1970: value.doubleValue)
        } else {
            expired = nil
        }

        return AuthFileDescriptor(
            id: url.path,
            providerID: providerID,
            email: email,
            login: login,
            expired: expired,
            accountType: json["account_type"] as? String,
            filePath: url.path,
            source: .cliProxyApi,
            filename: url.lastPathComponent,
            legacyIdentityKeys: legacyIdentityKeys
        )
    }

    private func parseAuthFileName(_ url: URL) -> AuthFileDescriptor? {
        let prefixes: [(String, String)] = [
            ("antigravity-", "antigravity"),
            ("codex-", "codex"),
            ("github-copilot-", "github-copilot"),
            ("claude-", "claude"),
            ("qwen-", "qwen"),
            ("iflow-", "iflow"),
            ("kiro-", "kiro"),
            ("vertex-", "vertex"),
        ]
        guard let match = prefixes.first(where: { url.lastPathComponent.hasPrefix($0.0) }) else {
            return nil
        }
        return AuthFileDescriptor(
            id: url.path,
            providerID: AccountProviderID(rawValue: match.1),
            email: extractEmail(from: url.lastPathComponent, prefix: match.0),
            login: nil,
            expired: nil,
            accountType: nil,
            filePath: url.path,
            source: .cliProxyApi,
            filename: url.lastPathComponent
        )
    }

    private func readKiroCredential(
        json: [String: Any],
        fileURL: URL
    ) -> AuthFileCredential? {
        guard let accessToken = json["access_token"] as? String
            ?? json["accessToken"] as? String else { return nil }
        let refreshToken = json["refresh_token"] as? String ?? json["refreshToken"] as? String
        let expiresAt = Self.expiryString(json)
        let authMethod = json["auth_method"] as? String
            ?? json["authMethod"] as? String
            ?? "IdC"
        var clientID = json["client_id"] as? String ?? json["clientId"] as? String
        var clientSecret = json["client_secret"] as? String ?? json["clientSecret"] as? String
        if authMethod.caseInsensitiveCompare("IdC") == .orderedSame,
           clientID == nil || clientSecret == nil,
           let registration = loadKiroDeviceRegistration() {
            clientID = registration.clientID
            clientSecret = registration.clientSecret
            updateKiroAuthFile(
                json: json,
                at: fileURL,
                clientID: registration.clientID,
                clientSecret: registration.clientSecret
            )
        }

        var extras: [String: String] = [:]
        if let startURL = json["start_url"] as? String ?? json["startUrl"] as? String {
            extras["start_url"] = startURL
        }
        if let region = json["region"] as? String { extras["region"] = region }
        if let profileARN = json["profile_arn"] as? String ?? json["profileArn"] as? String {
            extras["profileArn"] = profileARN
        }
        return AuthFileCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            clientID: clientID,
            clientSecret: clientSecret,
            authMethod: authMethod,
            extras: extras
        )
    }

    private func loadKiroDeviceRegistration() -> (clientID: String, clientSecret: String)? {
        let tokenURL = awsSSOCacheDirectory.appendingPathComponent("kiro-auth-token.json")
        if let data = fileManager.contents(atPath: tokenURL.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hash = json["clientIdHash"] as? String,
           let registration = deviceRegistration(
            at: awsSSOCacheDirectory.appendingPathComponent("\(hash).json")
           ) {
            return registration
        }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: awsSSOCacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return nil }
        return urls.lazy
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "kiro-auth-token.json" }
            .compactMap(deviceRegistration(at:))
            .first
    }

    private func deviceRegistration(at url: URL) -> (clientID: String, clientSecret: String)? {
        guard isRegularNonSymbolicFile(url),
              let data = fileManager.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["clientId"] as? String,
              let clientSecret = json["clientSecret"] as? String else { return nil }
        return (clientID, clientSecret)
    }

    private func updateKiroAuthFile(
        json: [String: Any],
        at url: URL,
        clientID: String,
        clientSecret: String
    ) {
        var updated = json
        updated["client_id"] = clientID
        updated["client_secret"] = clientSecret
        guard let data = try? JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? SecureAtomicFileWriter.write(data, to: url)
    }

    private func authFileURL(for name: String) throws -> URL {
        try validateAuthFileName(name)
        return authDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func validateAuthFileName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == name,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed.lowercased().hasSuffix(".json") else {
            throw AuthFileRepositoryError.invalidFileName
        }
    }

    private func validateAuthFileContent(_ content: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: content)
        } catch {
            throw AuthFileRepositoryError.invalidJSON(error.localizedDescription)
        }
        guard object is [String: Any] else {
            throw AuthFileRepositoryError.invalidJSON("JSON object required")
        }
    }

    private func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func extractEmail(from filename: String, prefix: String) -> String {
        var value = String(filename.dropFirst(prefix.count).dropLast(".json".count))
        let emailDomains = [
            "gmail.com", "googlemail.com", "outlook.com", "hotmail.com",
            "yahoo.com", "icloud.com", "protonmail.com", "proton.me",
        ]
        for domain in emailDomains {
            let suffix = "_" + domain.replacingOccurrences(of: ".", with: "_")
            if value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                return "\(value)@\(domain)"
            }
        }
        let parts = value.components(separatedBy: "_")
        if parts.count >= 3 {
            return parts.dropLast(2).joined(separator: ".")
                + "@"
                + parts.suffix(2).joined(separator: ".")
        }
        return parts.count == 2 ? parts.joined(separator: "@") : value
    }

    private func credential(accessToken: String) -> AuthFileCredential {
        AuthFileCredential(
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: nil,
            clientID: nil,
            clientSecret: nil,
            authMethod: nil,
            extras: nil
        )
    }

    private static func providerID(for type: String) -> AccountProviderID? {
        let canonical: [String: String] = [
            "antigravity": "antigravity",
            "claude": "claude",
            "codex": "codex",
            "copilot": "github-copilot",
            "github-copilot": "github-copilot",
            "qwen": "qwen",
            "iflow": "iflow",
            "kiro": "kiro",
            "vertex": "vertex",
            "cursor": "cursor",
            "trae": "trae",
        ]
        return canonical[type.lowercased()].map(AccountProviderID.init(rawValue:))
    }

    private static func firstNonBlank(_ values: String?...) -> String? {
        values.lazy.compactMap(nonBlank).first
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func expiryString(_ json: [String: Any]) -> String? {
        if let value = json["expires_at"] as? String
            ?? json["expiresAt"] as? String
            ?? json["expiry"] as? String {
            return value
        }
        let number = json["expires_at"] as? NSNumber
            ?? json["expiresAt"] as? NSNumber
            ?? json["expiry"] as? NSNumber
        return number.map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.doubleValue))
        }
    }
}
