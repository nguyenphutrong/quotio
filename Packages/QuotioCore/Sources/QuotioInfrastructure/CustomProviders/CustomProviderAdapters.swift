import Foundation
import QuotioApplication
import QuotioDomain

public final class UserDefaultsCustomProviderRepository: CustomProviderRepository, @unchecked Sendable {
    public static let storageKey = "customProviders"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> [CustomProvider] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CustomProvider].self, from: data)
    }

    public func save(_ providers: [CustomProvider]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        defaults.set(try encoder.encode(providers), forKey: Self.storageKey)
    }
}

public struct FileCustomProviderConfigurationSynchronizer:
    CustomProviderConfigurationSynchronizing,
    Sendable
{
    public init() {}

    public func synchronize(_ providers: [CustomProvider], at path: String) throws {
        var content = try String(contentsOfFile: path, encoding: .utf8)
        content = Self.removingManagedSections(from: content)
        let yaml = CustomProviderYAMLSerializer.sections(for: providers)
        if !yaml.isEmpty {
            content += "\n\n# Custom Providers (managed by Quotio)\n"
            content += yaml
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func removingManagedSections(from content: String) -> String {
        var result = content
        let sectionKeys = CustomProviderYAMLSerializer.sectionKeys
            .sorted()
            .map { "\($0):" }

        if let markerRange = result.range(of: "# Custom Providers (managed by Quotio)") {
            let followingContent = result[markerRange.upperBound...]
            let endIndex = firstUnmanagedSection(
                in: result,
                range: followingContent.startIndex..<followingContent.endIndex,
                managedKeys: sectionKeys
            ) ?? result.endIndex
            result.removeSubrange(markerRange.lowerBound..<endIndex)
        }

        for key in sectionKeys {
            result = removingSection(key, from: result)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingSection(_ key: String, from content: String) -> String {
        var result = content
        guard let startRange = result.range(of: "\n\(key)") ?? result.range(of: key) else {
            return result
        }
        guard startRange.upperBound < result.endIndex else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            return result
        }

        let searchStart = result.index(after: startRange.upperBound)
        guard searchStart < result.endIndex else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            return result
        }
        let nextSection = firstTopLevelSection(
            in: result,
            range: searchStart..<result.endIndex
        ) ?? result.endIndex
        result.removeSubrange(startRange.lowerBound..<nextSection)
        return result
    }

    private static func firstUnmanagedSection(
        in content: String,
        range: Range<String.Index>,
        managedKeys: [String]
    ) -> String.Index? {
        topLevelSectionRanges(in: content, range: range).first { candidate in
            !managedKeys.contains(String(content[candidate]))
        }?.lowerBound
    }

    private static func firstTopLevelSection(
        in content: String,
        range: Range<String.Index>
    ) -> String.Index? {
        topLevelSectionRanges(in: content, range: range).first?.lowerBound
    }

    private static func topLevelSectionRanges(
        in content: String,
        range: Range<String.Index>
    ) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^[a-z][\w-]*:"#) else {
            return []
        }
        return regex.matches(in: content, range: NSRange(range, in: content)).compactMap {
            Range($0.range, in: content)
        }
    }
}

public protocol CustomProviderHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: CustomProviderHTTPSession {}

public typealias CustomProviderTransportError = CustomProviderRemoteError

public actor URLSessionCustomProviderTransport: CustomProviderModelDiscovering, CustomProviderConnectionTesting {
    private let session: any CustomProviderHTTPSession

    public init(session: any CustomProviderHTTPSession = URLSession.shared) {
        self.session = session
    }

    public func discoverModels(for provider: CustomProvider) async throws -> [DiscoveredModel] {
        let request = try makeRequest(provider: provider, connectionTest: false)
        let (data, response) = try await session.data(for: request)
        let http = try validate(response: response, data: data)
        guard http.statusCode == 200 else {
            throw CustomProviderRemoteError.serverError(http.statusCode, "")
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.all.map {
            DiscoveredModel(
                id: $0.id,
                name: $0.name ?? $0.id,
                provider: $0.ownedBy ?? "unknown"
            )
        }
    }

    public func testConnection(to provider: CustomProvider) async throws {
        let request = try makeRequest(provider: provider, connectionTest: true)
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
    }

    public func makeRequest(provider: CustomProvider, connectionTest: Bool) throws -> URLRequest {
        guard let key = provider.apiKeys.first?.apiKey else {
            throw CustomProviderRemoteError.noAPIKey
        }
        let url: URL
        if provider.type == .clinePass && connectionTest {
            url = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!
        } else {
            let base = provider.baseURL.isEmpty
                ? (provider.type.defaultBaseURL ?? "")
                : CustomProviderEndpointPolicy.normalizedBaseURL(
                    provider.baseURL,
                    for: provider.type
                )
            guard let modelsURL = Self.modelsURL(baseURL: base, providerType: provider.type) else {
                throw CustomProviderRemoteError.invalidURL
            }
            url = modelsURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        switch provider.type {
        case .geminiCompatibility:
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "key", value: key)]
            request.url = components?.url
        case .claudeCompatibility:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for header in provider.effectiveHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if provider.type == .clinePass && connectionTest {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw CustomProviderRemoteError.invalidResponse
        }
        switch response.statusCode {
        case 200..<300: return response
        case 401, 403:
            throw CustomProviderRemoteError.unauthorized
        case 404:
            throw CustomProviderRemoteError.endpointNotFound
        default:
            throw CustomProviderRemoteError.serverError(
                response.statusCode,
                String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
    }

    public static func modelsURL(baseURL: String, providerType: CustomProviderType) -> URL? {
        let normalized = CustomProviderEndpointPolicy.normalizedBaseURL(baseURL, for: providerType)
        guard let url = URL(string: normalized) else { return nil }
        return url.appendingPathComponent(hasVersion(url.path) ? "models" : "v1/models")
    }
    private static func hasVersion(_ path: String) -> Bool {
        guard let segment = path.split(separator: "/").last, segment.first == "v" else { return false }
        let rest = segment.dropFirst(); guard rest.first?.isNumber == true else { return false }
        return rest.allSatisfy { $0.isNumber || $0.isLetter }
    }
}

private struct ModelsResponse: Decodable {
    let data: [Model]?
    let models: [Model]?

    var all: [Model] { data ?? models ?? [] }
}

private struct Model: Decodable {
    let id: String
    let name: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownedBy = "owned_by"
    }
}
