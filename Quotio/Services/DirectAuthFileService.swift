import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure

/// UI-safe compatibility value used by the quota slice until Phase 7 moves its models.
nonisolated struct DirectAuthFile: Identifiable, Sendable, Hashable {
    let id: String
    let provider: AIProvider
    let email: String?
    let login: String?
    let expired: Date?
    let accountType: String?
    let filePath: String
    let source: AuthFileSource
    let filename: String
    var legacyIdentityKeys: [String] = []

    enum AuthFileSource: String, Sendable {
        case cliProxyApi = "~/.cli-proxy-api"
        case nativeCredential = "Native Credential"

        var displayName: String {
            switch self {
            case .cliProxyApi: "CLI Proxy API"
            case .nativeCredential: "Native Credential"
            }
        }
    }

    var isExpired: Bool { expired.map { $0 < Date() } ?? false }
    var displayName: String { Self.nonBlank(email) ?? Self.nonBlank(login) ?? filename }

    init(
        id: String,
        provider: AIProvider,
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
        self.provider = provider
        self.email = email
        self.login = login
        self.expired = expired
        self.accountType = accountType
        self.filePath = filePath
        self.source = source
        self.filename = filename
        self.legacyIdentityKeys = legacyIdentityKeys
    }

    init?(_ descriptor: AuthFileDescriptor) {
        guard let provider = AIProvider(rawValue: descriptor.providerID.rawValue) else { return nil }
        id = descriptor.id
        self.provider = provider
        email = descriptor.email
        login = descriptor.login
        expired = descriptor.expired
        accountType = descriptor.accountType
        filePath = descriptor.filePath
        source = descriptor.source == .nativeCredential ? .nativeCredential : .cliProxyApi
        filename = descriptor.filename
        legacyIdentityKeys = descriptor.legacyIdentityKeys
    }

    nonisolated var menuBarAccountKey: String {
        switch provider {
        case .codex:
            filename.codexFilenameKey
        case .copilot:
            Self.nonBlank(login) ?? filename.copilotFilenameKey ?? filename
        case .kiro:
            Self.nonBlank(email) ?? filename.replacingOccurrences(of: ".json", with: "")
        default:
            Self.nonBlank(email) ?? filename
        }
    }

    private nonisolated static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DirectAuthFile, rhs: DirectAuthFile) -> Bool {
        lhs.id == rhs.id
    }
}

/// Migration bridge for the quota slice. Filesystem ownership lives in Infrastructure.
actor DirectAuthFileService {
    private let repository: any AuthFileRepository

    init(repository: any AuthFileRepository = FileAuthFileRepository()) {
        self.repository = repository
    }

    init(authDirectory: URL) {
        repository = FileAuthFileRepository(authDirectory: authDirectory)
    }

    func scanAllAuthFiles() async -> [DirectAuthFile] {
        await repository.scanAllAuthFiles().compactMap(DirectAuthFile.init)
    }

    func readAuthToken(from file: DirectAuthFile) async -> AuthTokenData? {
        let descriptor = Self.descriptor(from: file)
        guard let credential = await repository.readCredential(from: descriptor) else { return nil }
        return AuthTokenData(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt,
            clientId: credential.clientID,
            clientSecret: credential.clientSecret,
            authMethod: credential.authMethod,
            extras: credential.extras
        )
    }

    func uploadAuthFile(name: String, content: Data) async throws {
        do {
            try await repository.uploadAuthFile(name: name, content: content)
        } catch {
            throw Self.map(error)
        }
    }

    func readAuthFileForImport(from url: URL) async throws -> Data {
        do {
            return try await repository.readAuthFileForImport(from: url)
        } catch {
            throw Self.map(error)
        }
    }

    func writeDownloadedAuthFile(_ content: Data, to url: URL) async throws {
        do {
            try await repository.writeDownloadedAuthFile(content, to: url)
        } catch {
            throw Self.map(error)
        }
    }

    func downloadAuthFile(name: String) async throws -> Data {
        do {
            return try await repository.downloadAuthFile(name: name)
        } catch {
            throw Self.map(error)
        }
    }

    private nonisolated static func descriptor(from file: DirectAuthFile) -> AuthFileDescriptor {
        AuthFileDescriptor(
            id: file.id,
            providerID: AccountProviderID(rawValue: file.provider.rawValue),
            email: file.email,
            login: file.login,
            expired: file.expired,
            accountType: file.accountType,
            filePath: file.filePath,
            source: file.source == .nativeCredential ? .nativeCredential : .cliProxyApi,
            filename: file.filename,
            legacyIdentityKeys: file.legacyIdentityKeys
        )
    }

    private nonisolated static func map(_ error: Error) -> AuthFileError {
        guard let error = error as? AuthFileRepositoryError else {
            return .readFailed(error.localizedDescription)
        }
        return switch error {
        case .fileNotFound(let name): AuthFileError.fileNotFound(name)
        case .invalidFileName: AuthFileError.invalidFileName
        case .invalidJSON(let reason): AuthFileError.invalidJSON(reason)
        case .readFailed(let reason): AuthFileError.readFailed(reason)
        case .saveFailed(let reason): AuthFileError.saveFailed(reason)
        case .symbolicLinkRefused: AuthFileError.symbolicLinkRefused
        }
    }
}

enum AuthFileError: LocalizedError {
    case fileNotFound(String)
    case invalidFileName
    case invalidJSON(String)
    case readFailed(String)
    case saveFailed(String)
    case symbolicLinkRefused

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            String(format: "authFile.error.fileNotFound".localizedStatic(), name)
        case .invalidFileName:
            "authFile.error.invalidFileName".localizedStatic()
        case .invalidJSON(let reason):
            String(format: "authFile.error.invalidJSON".localizedStatic(), reason)
        case .readFailed(let reason):
            String(format: "authFile.error.readFailed".localizedStatic(), reason)
        case .saveFailed(let reason):
            String(format: "authFile.error.saveFailed".localizedStatic(), reason)
        case .symbolicLinkRefused:
            "authFile.error.invalidFileName".localizedStatic()
        }
    }
}

nonisolated struct AuthTokenData: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: String?
    let clientId: String?
    let clientSecret: String?
    let authMethod: String?
    let extras: [String: String]?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        return date.map { $0 < Date() } ?? false
    }
}
