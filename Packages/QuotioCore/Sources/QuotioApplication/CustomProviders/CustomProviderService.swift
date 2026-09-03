import Foundation
import QuotioDomain

public protocol CustomProviderRepository: Sendable {
    func load() throws -> [CustomProvider]
    func save(_ providers: [CustomProvider]) throws
}

public protocol CustomProviderConfigurationSynchronizing: Sendable {
    func synchronize(_ providers: [CustomProvider], at path: String) throws
}

public struct DiscoveredModel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: String

    public init(id: String, name: String, provider: String) {
        self.id = id
        self.name = name
        self.provider = provider
    }
}

public protocol CustomProviderModelDiscovering: Sendable {
    func discoverModels(for provider: CustomProvider) async throws -> [DiscoveredModel]
}

public protocol CustomProviderConnectionTesting: Sendable {
    func testConnection(to provider: CustomProvider) async throws
}

public enum CustomProviderServiceError: Error, Equatable {
    case providerNotFound
    case duplicateName
}

public enum CustomProviderRemoteError: Error, Equatable {
    case noAPIKey
    case invalidURL
    case invalidResponse
    case unauthorized
    case endpointNotFound
    case serverError(Int, String)
}

public enum CustomProviderEndpointPolicy {
    public static func normalizedBaseURL(
        _ rawValue: String,
        for type: CustomProviderType
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (type == .openaiCompatibility || type == .codexCompatibility),
              !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              !baseURLIncludesVersion(components.path) else {
            return trimmed
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        } else if components.path.hasSuffix("/") {
            components.path += "v1"
        } else {
            components.path += "/v1"
        }
        return components.string ?? trimmed
    }

    private static func baseURLIncludesVersion(_ path: String) -> Bool {
        guard let segment = path.split(separator: "/").last,
              segment.first == "v" else {
            return false
        }
        let remainder = segment.dropFirst()
        guard remainder.first?.isNumber == true else { return false }
        return remainder.allSatisfy { $0.isNumber || $0.isLetter }
    }
}

public struct CustomProviderService: Sendable {
    private let repository: any CustomProviderRepository
    private let discovery: any CustomProviderModelDiscovering
    private let connectionTester: any CustomProviderConnectionTesting
    private let configurationSynchronizer: (any CustomProviderConfigurationSynchronizing)?

    public init(
        repository: any CustomProviderRepository,
        discovery: any CustomProviderModelDiscovering,
        connectionTester: any CustomProviderConnectionTesting,
        configurationSynchronizer: (any CustomProviderConfigurationSynchronizing)? = nil
    ) {
        self.repository = repository
        self.discovery = discovery
        self.connectionTester = connectionTester
        self.configurationSynchronizer = configurationSynchronizer
    }

    public func providers() throws -> [CustomProvider] {
        try repository.load()
    }

    public func validationIssues(for provider: CustomProvider) throws -> [CustomProviderValidationIssue] {
        var issues = provider.validationIssues()
        let hasDuplicateName = try repository.load().contains {
            $0.id != provider.id && $0.name.caseInsensitiveCompare(provider.name) == .orderedSame
        }
        if hasDuplicateName {
            issues.append(.duplicateName)
        }
        return issues
    }

    public func save(_ provider: CustomProvider, now: Date = Date()) throws {
        var providers = try repository.load()
        guard !providers.contains(where: {
            $0.id != provider.id && $0.name.caseInsensitiveCompare(provider.name) == .orderedSame
        }) else {
            throw CustomProviderServiceError.duplicateName
        }
        var value = provider
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            value.createdAt = providers[index].createdAt
            value.updatedAt = now
            providers[index] = value
        } else {
            value.createdAt = now
            value.updatedAt = now
            providers.append(value)
        }
        try repository.save(providers)
    }

    public func delete(id: UUID) throws {
        var values = try repository.load()
        values.removeAll { $0.id == id }
        try repository.save(values)
    }

    public func synchronizeConfiguration(at path: String) throws {
        guard let configurationSynchronizer else { return }
        try configurationSynchronizer.synchronize(try repository.load(), at: path)
    }

    public func discoverModels(for provider: CustomProvider) async throws -> [DiscoveredModel] {
        try await discovery.discoverModels(for: provider)
    }

    public func testConnection(to provider: CustomProvider) async throws {
        try await connectionTester.testConnection(to: provider)
    }
}
