//
//  AtomFeedUpdateService.swift
//  Quotio
//
//  Efficient update checking via GitHub Atom feeds with ETag caching.
//  Uses conditional requests (If-None-Match) to minimize bandwidth and avoid rate limits.
//

import Foundation
import Observation

// MARK: - Atom Feed Entry

struct AtomFeedEntry: Sendable {
    let id: String
    let version: String
    let title: String
    let updated: Date
    let link: String
}

// MARK: - Atom Feed Result

enum AtomFeedResult: Sendable {
    /// New entries available (feed was modified)
    case updated(entries: [AtomFeedEntry], etag: String?)
    /// No changes since last check (304 Not Modified)
    case notModified
    /// Error occurred during fetch
    case error(Error)
}

// MARK: - Cached Feed State

struct CachedFeedState: Codable, Sendable {
    let etag: String?
    let lastModified: String?
    let latestVersion: String
    let lastChecked: Date
}

// MARK: - AtomFeedUpdateService

@MainActor
@Observable
final class AtomFeedUpdateService {

    static let shared = AtomFeedUpdateService()

    // MARK: - Feed URLs

    private static let cliProxyFeedURL = "https://github.com/router-for-me/CLIProxyAPIPlus/releases.atom"
    private static let quotioFeedURL = "https://github.com/nguyenphutrong/quotio/releases.atom"

    // MARK: - Cache Keys

    private static let cliProxyCacheKey = "atomFeedCache_cliproxy"
    private static let quotioCacheKey = "atomFeedCache_quotio"

    // MARK: - Polling Configuration

    /// Polling interval in seconds (5 minutes)
    private static let pollingIntervalSeconds: UInt64 = 5 * 60

    // MARK: - Observable Properties

    /// Whether CLIProxyAPI has an update available
    private(set) var cliProxyUpdateAvailable: Bool = false

    /// Latest available CLIProxyAPI version
    private(set) var latestCLIProxyVersion: String?

    /// Last time CLIProxyAPI was checked
    private(set) var lastCLIProxyCheck: Date?

    /// Whether a check is in progress
    private(set) var isChecking: Bool = false

    // MARK: - Private Properties

    private var pollingTask: Task<Void, Never>?
    private var isPollingEnabled: Bool = false

    /// Shared URLSession for all feed requests (avoids creating new sessions per request)
    @ObservationIgnored
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil // Don't cache, we use ETag
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dateFormatterFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Public API

    /// Check for CLIProxyAPI updates using Atom feed with ETag caching.
    /// Returns the latest version if an update is available, nil if up-to-date or error.
    func checkForCLIProxyUpdate(currentVersion: String?) async -> (latestVersion: String?, isNewRelease: Bool) {
        let result = await fetchAtomFeed(
            url: Self.cliProxyFeedURL,
            cacheKey: Self.cliProxyCacheKey
        )

        switch result {
        case .updated(let entries, let etag):
            guard let latest = entries.first else {
                return (nil, false)
            }

            // Save cache state
            saveCacheState(
                cacheKey: Self.cliProxyCacheKey,
                etag: etag,
                latestVersion: latest.version
            )

            // Compare versions
            let isNewer: Bool
            if let current = currentVersion {
                isNewer = isNewerVersion(latest.version, than: current)
            } else {
                isNewer = true
            }
            return (latest.version, isNewer)

        case .notModified:
            // Feed hasn't changed, check cached version
            if let cached = loadCacheState(cacheKey: Self.cliProxyCacheKey) {
                let isNewer: Bool
                if let current = currentVersion {
                    isNewer = isNewerVersion(cached.latestVersion, than: current)
                } else {
                    isNewer = true
                }
                return (cached.latestVersion, isNewer)
            }
            return (nil, false)

        case .error(let error):
            NSLog("[AtomFeedUpdateService] CLIProxy feed error: \(error.localizedDescription)")
            return (nil, false)
        }
    }

    /// Check for Quotio app updates using Atom feed.
    /// This is a lightweight pre-check before Sparkle does its full update cycle.
    func checkForQuotioUpdate(currentVersion: String?) async -> (latestVersion: String?, isNewRelease: Bool) {
        let result = await fetchAtomFeed(
            url: Self.quotioFeedURL,
            cacheKey: Self.quotioCacheKey
        )

        switch result {
        case .updated(let entries, let etag):
            guard let latest = entries.first else {
                return (nil, false)
            }

            saveCacheState(
                cacheKey: Self.quotioCacheKey,
                etag: etag,
                latestVersion: latest.version
            )

            let isNewer: Bool
            if let current = currentVersion {
                isNewer = isNewerVersion(latest.version, than: current)
            } else {
                isNewer = true
            }
            return (latest.version, isNewer)

        case .notModified:
            if let cached = loadCacheState(cacheKey: Self.quotioCacheKey) {
                let isNewer: Bool
                if let current = currentVersion {
                    isNewer = isNewerVersion(cached.latestVersion, than: current)
                } else {
                    isNewer = true
                }
                return (cached.latestVersion, isNewer)
            }
            return (nil, false)

        case .error(let error):
            NSLog("[AtomFeedUpdateService] Quotio feed error: \(error.localizedDescription)")
            return (nil, false)
        }
    }

    /// Force refresh without using cached ETag (for manual "Check for Updates" button)
    func forceCheckForCLIProxyUpdate(currentVersion: String?) async -> (latestVersion: String?, isNewRelease: Bool) {
        // Clear cached ETag to force full fetch
        UserDefaults.standard.removeObject(forKey: Self.cliProxyCacheKey)
        return await checkForCLIProxyUpdate(currentVersion: currentVersion)
    }

    // MARK: - Background Polling

    /// Start background polling for CLIProxyAPI updates.
    /// Polls every 5 minutes using ETag caching for efficiency.
    /// - Parameter getCurrentVersion: Closure that returns the current installed version
    func startPolling(getCurrentVersion: @escaping () -> String?) {
        guard !isPollingEnabled else { return }
        isPollingEnabled = true

        NSLog("[AtomFeedUpdateService] Starting background polling (interval: \(Self.pollingIntervalSeconds)s)")

        pollingTask = Task { [weak self] in
            // Initial check after short delay
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000) // 5 seconds

            while !Task.isCancelled {
                guard let self = self else { break }

                await self.performPollingCheck(getCurrentVersion: getCurrentVersion)

                // Wait for next polling interval
                try? await Task.sleep(nanoseconds: Self.pollingIntervalSeconds * 1_000_000_000)
            }
        }
    }

    /// Stop background polling.
    func stopPolling() {
        isPollingEnabled = false
        pollingTask?.cancel()
        pollingTask = nil
        // Invalidate URLSession to release connections
        urlSession.invalidateAndCancel()
        NSLog("[AtomFeedUpdateService] Stopped background polling")
    }

    /// Perform a single polling check and update observable state.
    private func performPollingCheck(getCurrentVersion: () -> String?) async {
        isChecking = true
        defer { isChecking = false }

        let currentVersion = getCurrentVersion()
        let (latestVersion, isNewer) = await checkForCLIProxyUpdate(currentVersion: currentVersion)

        lastCLIProxyCheck = Date()
        latestCLIProxyVersion = latestVersion

        if isNewer && latestVersion != nil {
            // Only notify if this is a NEW update (not previously notified)
            let notifiedKey = "notifiedCLIProxyVersion"
            let previouslyNotified = UserDefaults.standard.string(forKey: notifiedKey)

            if previouslyNotified != latestVersion {
                cliProxyUpdateAvailable = true
                UserDefaults.standard.set(latestVersion, forKey: notifiedKey)

                // Send system notification
                if let version = latestVersion {
                    NotificationManager.shared.notifyUpgradeAvailable(version: version)
                    NSLog("[AtomFeedUpdateService] New CLIProxyAPI version available: \(version)")
                }
            }
        } else {
            cliProxyUpdateAvailable = false
        }
    }

    /// Manually trigger an update check (for "Check for Updates" button).
    /// This bypasses the ETag cache to force a fresh check.
    func manualCheckForCLIProxyUpdate(currentVersion: String?) async {
        isChecking = true
        defer { isChecking = false }

        let (latestVersion, isNewer) = await forceCheckForCLIProxyUpdate(currentVersion: currentVersion)

        lastCLIProxyCheck = Date()
        latestCLIProxyVersion = latestVersion
        cliProxyUpdateAvailable = isNewer && latestVersion != nil

        if cliProxyUpdateAvailable, let version = latestVersion {
            NSLog("[AtomFeedUpdateService] Manual check: CLIProxyAPI \(version) available")
        } else {
            NSLog("[AtomFeedUpdateService] Manual check: CLIProxyAPI is up to date")
        }
    }

    /// Reset the "already notified" state (e.g., after user updates)
    func resetNotificationState() {
        UserDefaults.standard.removeObject(forKey: "notifiedCLIProxyVersion")
        cliProxyUpdateAvailable = false
    }

    // MARK: - Private Methods

    private func fetchAtomFeed(url: String, cacheKey: String) async -> AtomFeedResult {
        guard let feedURL = URL(string: url) else {
            return .error(AtomFeedError.invalidURL)
        }

        var request = URLRequest(url: feedURL)
        request.addValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        // Add conditional request headers if we have cached state
        if let cached = loadCacheState(cacheKey: cacheKey) {
            if let etag = cached.etag {
                request.addValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = cached.lastModified {
                request.addValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error(AtomFeedError.invalidResponse)
            }

            switch httpResponse.statusCode {
            case 200:
                // Feed was modified, parse it
                let entries = parseAtomFeed(data: data)
                let etag = httpResponse.value(forHTTPHeaderField: "ETag")
                return .updated(entries: entries, etag: etag)

            case 304:
                // Not modified
                return .notModified

            default:
                return .error(AtomFeedError.httpError(httpResponse.statusCode))
            }

        } catch {
            return .error(error)
        }
    }

    private func parseAtomFeed(data: Data) -> [AtomFeedEntry] {
        let parser = AtomFeedParser(data: data)
        return parser.parse()
    }

    private func saveCacheState(cacheKey: String, etag: String?, latestVersion: String) {
        let state = CachedFeedState(
            etag: etag,
            lastModified: nil,
            latestVersion: latestVersion,
            lastChecked: Date()
        )

        if let encoded = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }

    private func loadCacheState(cacheKey: String) -> CachedFeedState? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let state = try? JSONDecoder().decode(CachedFeedState.self, from: data) else {
            return nil
        }
        return state
    }

    /// Compare two semantic version strings.
    /// Returns true if `newer` is greater than `older`.
    private func isNewerVersion(_ newer: String, than older: String) -> Bool {
        func parseVersion(_ version: String) -> [Int] {
            // Remove 'v' prefix if present
            let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version

            // Split by "-" to separate version from build number
            let dashParts = cleaned.split(separator: "-")
            let mainVersion = String(dashParts.first ?? "")
            let buildNumber = dashParts.count > 1 ? Int(dashParts[1]) : nil

            // Split main version by "."
            var parts = mainVersion.split(separator: ".").compactMap { Int($0) }

            // Append build number if present
            if let build = buildNumber {
                parts.append(build)
            }

            return parts
        }

        let newerParts = parseVersion(newer)
        let olderParts = parseVersion(older)

        let maxLength = max(newerParts.count, olderParts.count)
        let paddedNewer = newerParts + Array(repeating: 0, count: maxLength - newerParts.count)
        let paddedOlder = olderParts + Array(repeating: 0, count: maxLength - olderParts.count)

        for (n, o) in zip(paddedNewer, paddedOlder) {
            if n > o { return true }
            if n < o { return false }
        }

        return false
    }
}

// MARK: - Atom Feed Parser

private class AtomFeedParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var entries: [AtomFeedEntry] = []

    private var currentElement: String = ""
    private var currentEntry: (id: String, version: String, title: String, updated: Date, link: String)?
    private var currentText: String = ""
    private var isInEntry: Bool = false

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dateFormatterFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(data: Data) {
        self.data = data
        super.init()
    }

    func parse() -> [AtomFeedEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" {
            isInEntry = true
            currentEntry = ("", "", "", Date(), "")
        }

        if elementName == "link" && isInEntry {
            if let href = attributeDict["href"], attributeDict["rel"] == "alternate" {
                currentEntry?.link = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInEntry {
            switch elementName {
            case "id":
                currentEntry?.id = trimmedText
                // Extract version from ID (format: "tag:github.com,2008:Repository/xxx/v6.7.13")
                if let versionPart = trimmedText.split(separator: "/").last {
                    currentEntry?.version = String(versionPart)
                }
            case "title":
                currentEntry?.title = trimmedText
                // Also try to extract version from title if not found in ID
                if currentEntry?.version.isEmpty == true {
                    currentEntry?.version = trimmedText
                }
            case "updated":
                if let date = dateFormatter.date(from: trimmedText) ?? dateFormatterFallback.date(from: trimmedText) {
                    currentEntry?.updated = date
                }
            case "entry":
                if let entry = currentEntry {
                    entries.append(AtomFeedEntry(
                        id: entry.id,
                        version: entry.version,
                        title: entry.title,
                        updated: entry.updated,
                        link: entry.link
                    ))
                }
                isInEntry = false
                currentEntry = nil
            default:
                break
            }
        }

        currentElement = ""
    }
}

// MARK: - Errors

enum AtomFeedError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid feed URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .parseError:
            return "Failed to parse feed"
        }
    }
}
