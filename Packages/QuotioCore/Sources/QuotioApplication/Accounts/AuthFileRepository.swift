import Foundation
import QuotioDomain

public enum AuthFileSource: String, Sendable {
    case cliProxyApi = "~/.cli-proxy-api"
    case nativeCredential = "Native Credential"
}

public struct AuthFileDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let providerID: AccountProviderID
    public let email: String?
    public let login: String?
    public let expired: Date?
    public let accountType: String?
    public let filePath: String
    public let source: AuthFileSource
    public let filename: String
    public var legacyIdentityKeys: [String]

    public init(
        id: String,
        providerID: AccountProviderID,
        email: String?,
        login: String?,
        expired: Date?,
        accountType: String?,
        filePath: String,
        source: AuthFileSource,
        filename: String,
        legacyIdentityKeys: [String] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.email = email
        self.login = login
        self.expired = expired
        self.accountType = accountType
        self.filePath = filePath
        self.source = source
        self.filename = filename
        self.legacyIdentityKeys = legacyIdentityKeys
    }

    public var isExpired: Bool {
        expired.map { $0 < Date() } ?? false
    }

    public var displayName: String {
        email?.nilIfBlank ?? login?.nilIfBlank ?? filename
    }

    public var menuBarAccountKey: String {
        switch providerID.rawValue {
        case "codex":
            return filename.removing(prefix: "codex-").removing(suffix: ".json")
        case "github-copilot", "copilot":
            return login?.nilIfBlank
                ?? filename.removing(prefix: "github-copilot-").removing(suffix: ".json")
        case "kiro":
            return email?.nilIfBlank ?? filename.removing(suffix: ".json")
        default:
            return email?.nilIfBlank ?? filename
        }
    }
}

public struct AuthFileCredential: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: String?
    public let clientID: String?
    public let clientSecret: String?
    public let authMethod: String?
    public let extras: [String: String]?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: String?,
        clientID: String?,
        clientSecret: String?,
        authMethod: String?,
        extras: [String: String]?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authMethod = authMethod
        self.extras = extras
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        return date.map { $0 < Date() } ?? false
    }
}

public enum AuthFileRepositoryError: Error, Equatable, Sendable {
    case fileNotFound(String)
    case invalidFileName
    case invalidJSON(String)
    case readFailed(String)
    case saveFailed(String)
    case symbolicLinkRefused
}

public protocol AuthFileRepository: Sendable {
    func scanAllAuthFiles() async -> [AuthFileDescriptor]
    func readCredential(from file: AuthFileDescriptor) async -> AuthFileCredential?
    func uploadAuthFile(name: String, content: Data) async throws
    func readAuthFileForImport(from url: URL) async throws -> Data
    func writeDownloadedAuthFile(_ content: Data, to url: URL) async throws
    func downloadAuthFile(name: String) async throws -> Data
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func removing(prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func removing(suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
