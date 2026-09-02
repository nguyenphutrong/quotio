import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain

public enum ProxyURLSessionFactory {
    public static func makeConfiguration(
        timeout: TimeInterval,
        defaults: UserDefaults = .standard
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        guard let rawValue = defaults.string(forKey: "proxyURL"),
              let proxyURL = validatedProxyURL(rawValue),
              let host = proxyURL.host else {
            return configuration
        }
        let port = proxyURL.port ?? (proxyURL.scheme == "https" ? 443 : 8080)
        var dictionary: [AnyHashable: Any] = [:]
        switch proxyURL.scheme?.lowercased() {
        case "http":
            dictionary[kCFNetworkProxiesHTTPEnable] = true
            dictionary[kCFNetworkProxiesHTTPProxy] = host
            dictionary[kCFNetworkProxiesHTTPPort] = port
            dictionary[kCFNetworkProxiesHTTPSEnable] = true
            dictionary[kCFNetworkProxiesHTTPSProxy] = host
            dictionary[kCFNetworkProxiesHTTPSPort] = port
        case "https":
            dictionary[kCFNetworkProxiesHTTPSEnable] = true
            dictionary[kCFNetworkProxiesHTTPSProxy] = host
            dictionary[kCFNetworkProxiesHTTPSPort] = port
        case "socks5":
            dictionary[kCFStreamPropertySOCKSProxyHost] = host
            dictionary[kCFStreamPropertySOCKSProxyPort] = port
            dictionary[kCFStreamPropertySOCKSVersion] = kCFStreamSocketSOCKSVersion5
            if let user = proxyURL.user {
                dictionary[kCFStreamPropertySOCKSUser] = user
            }
            if let password = proxyURL.password {
                dictionary[kCFStreamPropertySOCKSPassword] = password
            }
        default:
            return configuration
        }
        configuration.connectionProxyDictionary = dictionary
        return configuration
    }

    private static func validatedProxyURL(_ value: String) -> URL? {
        var sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasSuffix("/") {
            sanitized.removeLast()
        }
        guard !sanitized.isEmpty,
              let url = URL(string: sanitized),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "socks5"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        if scheme == "socks5", url.port == nil {
            return nil
        }
        if let port = url.port, !(1...65_535).contains(port) {
            return nil
        }
        return url
    }
}

public actor GitHubProxyReleaseRepository: ProxyReleaseRepository {
    private struct ReleaseDTO: Decodable {
        let tagName: String
        let body: String?
        let assets: [AssetDTO]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String
        let digest: String?
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
            case size
        }
    }

    private let session: URLSession
    private let repository: String

    public init(
        session: URLSession = URLSession(
            configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 30)
        ),
        repository: String = "router-for-me/CLIProxyAPI"
    ) {
        self.session = session
        self.repository = repository
    }

    public func latestRelease() async throws -> ProxyVersionInfo {
        let release: ReleaseDTO = try await fetch(path: "releases/latest")
        return try map(release)
    }

    public func release(tag: String) async throws -> ProxyVersionInfo {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let release: ReleaseDTO = try await fetch(path: "releases/tags/\(encodedTag)")
        return try map(release)
    }

    public func releases(limit: Int) async throws -> [ProxyVersionInfo] {
        let releases: [ReleaseDTO] = try await fetch(path: "releases?per_page=\(limit)")
        return releases.compactMap { try? map($0) }
    }

    private func fetch<Value: Decodable>(path: String) async throws -> Value {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/\(path)") else {
            throw ProxyFailure.network("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                throw ProxyFailure.network("Failed to fetch release information")
            }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let failure as ProxyFailure {
            throw failure
        } catch {
            throw ProxyFailure.network(String(describing: error))
        }
    }

    private func map(_ release: ReleaseDTO) throws -> ProxyVersionInfo {
        guard let asset = compatibleAsset(in: release.assets) else {
            throw ProxyFailure.noCompatibleBinary
        }
        guard let digest = asset.digest,
              digest.hasPrefix("sha256:"),
              !digest.dropFirst(7).isEmpty else {
            throw ProxyFailure.checksumMissing
        }
        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName
        return ProxyVersionInfo(
            version: version,
            sha256: String(digest.dropFirst(7)),
            downloadURL: asset.browserDownloadURL,
            releaseNotes: release.body,
            size: asset.size
        )
    }

    private func compatibleAsset(in assets: [AssetDTO]) -> AssetDTO? {
        #if arch(arm64)
        let targets = ["darwin_arm64", "darwin_aarch64"]
        #else
        let targets = ["darwin_amd64"]
        #endif
        return assets.first { asset in
            let name = asset.name.lowercased()
            let isExcluded = ["windows", "linux", "checksum"].contains {
                name.contains($0)
            }
            return !isExcluded && targets.contains(where: name.contains)
        }
    }
}

public actor URLSessionProxyBinaryDownloader: ProxyBinaryDownloading {
    private let session: URLSession

    public init(
        session: URLSession = URLSession(
            configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 300)
        )
    ) {
        self.session = session
    }

    public func download(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw ProxyFailure.network("Invalid download URL")
        }
        var request = URLRequest(url: url)
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                throw ProxyFailure.downloadFailed("Failed to download binary")
            }
            return data
        } catch let failure as ProxyFailure {
            throw failure
        } catch {
            throw ProxyFailure.downloadFailed(String(describing: error))
        }
    }

    public func readLocalFile(at path: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProxyFailure.downloadFailed("Local binary not found at \(path)")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}

public struct SHA256ProxyChecksumVerifier: ProxyChecksumVerifying {
    public init() {}

    public func verify(_ data: Data, expectedSHA256: String) throws {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.lowercased() == expectedSHA256.lowercased() else {
            throw ProxyFailure.checksumMismatch(
                expected: expectedSHA256,
                actual: digest
            )
        }
    }
}

public actor LocalProxyManagementClient: ProxyManagementChecking {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func isHealthy(
        endpoint: ProxyEndpoint,
        managementKey: String,
        timeout: Duration
    ) async -> Bool {
        guard let request = makeRequest(
            endpoint: endpoint,
            managementKey: managementKey,
            timeout: timeout
        ) else {
            return false
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return 200...299 ~= response.statusCode
        } catch {
            return false
        }
    }

    public func compatibility(
        endpoint: ProxyEndpoint,
        managementKey: String
    ) async -> ProxyCompatibilityResult {
        guard await isHealthy(
            endpoint: endpoint,
            managementKey: managementKey,
            timeout: .seconds(3)
        ) else {
            return .proxyNotRunning
        }
        return .compatible
    }

    private func makeRequest(
        endpoint: ProxyEndpoint,
        managementKey: String,
        timeout: Duration
    ) -> URLRequest? {
        guard let url = URL(string: "\(endpoint.managementURL)/debug") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let components = timeout.components
        request.timeoutInterval = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        request.addValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
