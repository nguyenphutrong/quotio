import Foundation
import QuotioApplication

public actor GitHubAtomProxyUpdateFeed: ProxyUpdateFeedChecking {
    private static let cacheKey = "atomFeedCache_cliproxy"

    private let feedURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(
        feedURL: URL = URL(
            string: "https://github.com/router-for-me/CLIProxyAPI/releases.atom"
        )!,
        session: URLSession? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.feedURL = feedURL
        self.session = session ?? Self.makeSession()
        self.defaults = defaults
        self.now = now
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func latestVersion(comparedTo currentVersion: String?) async -> String? {
        let latestVersion: String?
        var request = URLRequest(url: feedURL)
        request.addValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        if let cached = loadCache() {
            if let etag = cached.etag {
                request.addValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = cached.lastModified {
                request.addValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return nil }
            switch response.statusCode {
            case 200:
                latestVersion = AtomFeedParser(data: data).parse().first
                if let latestVersion {
                    saveCache(
                        CachedFeedState(
                            etag: response.value(forHTTPHeaderField: "ETag"),
                            lastModified: nil,
                            latestVersion: latestVersion,
                            lastChecked: now()
                        )
                    )
                }
            case 304:
                latestVersion = loadCache()?.latestVersion
            default:
                return nil
            }
        } catch {
            return nil
        }

        guard let latestVersion else { return nil }
        guard let currentVersion else { return latestVersion }
        return Self.isNewer(latestVersion, than: currentVersion) ? latestVersion : nil
    }

    private func loadCache() -> CachedFeedState? {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedFeedState.self, from: data)
    }

    private func saveCache(_ state: CachedFeedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private static func isNewer(_ newer: String, than older: String) -> Bool {
        func components(_ version: String) -> [Int] {
            let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version
            let sections = cleaned.split(separator: "-")
            var parts = String(sections.first ?? "").split(separator: ".").compactMap { Int($0) }
            if sections.count > 1, let build = Int(sections[1]) {
                parts.append(build)
            }
            return parts
        }

        let newerParts = components(newer)
        let olderParts = components(older)
        let count = max(newerParts.count, olderParts.count)
        let paddedNewer = newerParts + Array(repeating: 0, count: count - newerParts.count)
        let paddedOlder = olderParts + Array(repeating: 0, count: count - olderParts.count)
        return paddedNewer.lexicographicallyPrecedes(paddedOlder) == false
            && paddedNewer != paddedOlder
    }
}

private struct CachedFeedState: Codable {
    let etag: String?
    let lastModified: String?
    let latestVersion: String
    let lastChecked: Date
}

private final class AtomFeedParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var versions: [String] = []
    private var isInEntry = false
    private var currentElement = ""
    private var currentText = ""
    private var currentVersion = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return versions
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "entry" {
            isInEntry = true
            currentVersion = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard isInEntry else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "id":
            if let version = text.split(separator: "/").last {
                currentVersion = String(version)
            }
        case "title" where currentVersion.isEmpty:
            currentVersion = text
        case "entry":
            if !currentVersion.isEmpty {
                versions.append(currentVersion)
            }
            isInEntry = false
        default:
            break
        }
        currentElement = ""
    }
}
