//
//  ProxyVersionModels.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Models for managed proxy versioning and compatibility checking.
//

import Foundation

// MARK: - Proxy Binary Source

nonisolated enum ProxyBinarySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpaPlusPlus = "cpa-plusplus"

    static let userDefaultsKey = "selectedProxyBinarySource"
    static let explicitSelectionDefaultsKey = "hasExplicitProxyBinarySourceSelection"
    static let devBinaryPathEnvironmentKey = "CPA_PLUSPLUS_BINARY_PATH"
    static let binaryName = "cpa-plusplus"
    static let legacyBinaryName = "CLIProxyAPI"

    var id: String { rawValue }

    var storageDirectoryName: String {
        switch self {
        case .cpaPlusPlus: return "cpa-plusplus"
        }
    }

    var displayName: String {
        switch self {
        case .cpaPlusPlus:
            return "cpa-plusplus"
        }
    }

    var shortDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "Fork-managed proxy server"
        }
    }

    var selectionDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "cpa-plusplus"
        }
    }

    var detailDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "Managed through the cpa-plusplus Management API."
        }
    }

    var installActionTitle: String {
        switch self {
        case .cpaPlusPlus:
            return "Install cpa-plusplus"
        }
    }

    var notInstalledTitle: String {
        switch self {
        case .cpaPlusPlus:
            return "cpa-plusplus Not Installed"
        }
    }

    var installDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "Install cpa-plusplus to continue local mode."
        }
    }

    var githubRepo: String? {
        switch self {
        case .cpaPlusPlus:
            return "nguyenphutrong/cpa-plusplus"
        }
    }

    var releasesFeedURL: String? {
        switch self {
        case .cpaPlusPlus:
            return "https://github.com/nguyenphutrong/cpa-plusplus/releases.atom"
        }
    }

    var binaryName: String {
        switch self {
        case .cpaPlusPlus:
            return Self.binaryName
        }
    }

    var sourceRepo: String {
        githubRepo ?? "local"
    }

    var installedVersionDefaultsKey: String {
        "installedProxyVersion_\(rawValue)"
    }

    var notificationVersionKey: String {
        "notifiedCLIProxyVersion_\(rawValue)"
    }

    var legacyAuthWarning: String? {
        switch self {
        case .cpaPlusPlus:
            return nil
        }
    }

    var installHint: String {
        switch self {
        case .cpaPlusPlus:
            return "cpa-plusplus is not installed. Install a release or set CPA_PLUSPLUS_BINARY_PATH for local development."
        }
    }
}

// MARK: - cpa-plusplus Version Tags

nonisolated struct CPAPlusPlusVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let plus: Int

    init?(_ rawValue: String) {
        var cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") {
            cleaned.removeFirst()
        }

        let parts = cleaned.components(separatedBy: "-plus.")
        guard parts.count == 2,
              let plus = Int(parts[1]) else {
            return nil
        }

        let semver = parts[0].split(separator: ".").compactMap { Int($0) }
        guard semver.count == 3 else { return nil }

        self.major = semver[0]
        self.minor = semver[1]
        self.patch = semver[2]
        self.plus = plus
    }

    static func < (lhs: CPAPlusPlusVersion, rhs: CPAPlusPlusVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.plus < rhs.plus
    }
}

// MARK: - GitHub Release Models

/// GitHub release information.
nonisolated struct GitHubRelease: Codable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]
    let prerelease: Bool
    let publishedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case assets
        case prerelease
        case publishedAt = "published_at"
    }
    
    /// Extract version string from tag name (removes 'v' prefix if present).
    var versionString: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    var isCPAPlusPlusRelease: Bool {
        CPAPlusPlusVersion(tagName) != nil
    }
}

/// GitHub release asset information.
nonisolated struct GitHubAsset: Codable, Sendable {
    let name: String
    let browserDownloadUrl: String
    let digest: String?
    let size: Int
    let contentType: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case digest
        case size
        case contentType = "content_type"
    }
    
    /// Extract SHA256 checksum from digest field (format: "sha256:...")
    var sha256Checksum: String? {
        guard let digest = digest, digest.hasPrefix("sha256:") else { return nil }
        return String(digest.dropFirst(7))
    }
}

// MARK: - Proxy Version Info

/// Information about a specific proxy version (simplified).
nonisolated struct ProxyVersionInfo: Sendable, Identifiable, Equatable {
    let source: ProxyBinarySource
    /// Semantic version string (e.g., "6.6.68-0")
    let version: String
    
    /// SHA256 checksum of the binary for verification
    let sha256: String
    
    /// Download URL for this version
    let downloadURL: String?
    
    /// Release notes or changelog (optional)
    let releaseNotes: String?
    
    /// Asset file size in bytes
    let size: Int?
    
    let localFilePath: String?

    var id: String { "\(source.rawValue):\(version)" }
    
    /// Create from GitHub release and compatible asset.
    /// Note: Returns nil if no valid SHA256 checksum is available.
    init?(from release: GitHubRelease, asset: GitHubAsset, source: ProxyBinarySource) {
        guard let checksum = asset.sha256Checksum,
              !checksum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.source = source
        self.version = release.versionString
        self.sha256 = checksum
        self.downloadURL = asset.browserDownloadUrl
        self.releaseNotes = release.body
        self.size = asset.size
        self.localFilePath = nil
    }
    
    /// Create manually.
    init(source: ProxyBinarySource, version: String, sha256: String, downloadURL: String? = nil, localFilePath: String? = nil, releaseNotes: String? = nil, size: Int? = nil) {
        self.source = source
        self.version = version
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.localFilePath = localFilePath
        self.releaseNotes = releaseNotes
        self.size = size
    }
}

// MARK: - Compatibility Check Result

/// Result of a compatibility check.
nonisolated enum CompatibilityCheckResult: Sendable {
    case compatible
    case proxyNotResponding
    case proxyNotRunning
    case connectionError(String)
    
    var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }
    
    var description: String {
        switch self {
        case .compatible:
            return "Proxy is compatible"
        case .proxyNotResponding:
            return "Proxy is not responding to API requests"
        case .proxyNotRunning:
            return "Proxy is not running"
        case .connectionError(let message):
            return "Connection error: \(message)"
        }
    }
}

// MARK: - Proxy Manager State

/// State machine for proxy upgrade flow.
nonisolated enum ProxyManagerState: String, Sendable {
    /// No proxy is running.
    case idle
    
    /// Active proxy is running normally.
    case active
    
    /// Testing a new proxy version in dry-run mode.
    case testing
    
    /// Performing rollback to previous version.
    case rollingBack
    
    /// Promoting tested version to active.
    case promoting
}

/// Information about an installed proxy version.
nonisolated struct InstalledProxyVersion: Sendable, Identifiable, Equatable {
    let source: ProxyBinarySource
    let version: String
    let path: String
    let installedAt: Date
    let isCurrent: Bool
    let binaryKind: String
    let sourceRepo: String
    
    var id: String { "\(source.rawValue):\(version)" }
}

nonisolated struct ProxyInstallMetadata: Codable, Sendable {
    let binaryKind: String
    let version: String
    let installedAt: Date
    let sourceRepo: String
}

// MARK: - Upgrade Errors

/// Errors that can occur during proxy upgrade.
nonisolated enum ProxyUpgradeError: LocalizedError, Sendable {
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case installationFailed(String)
    case compatibilityCheckFailed(CompatibilityCheckResult)
    case dryRunFailed(String)
    case rollbackFailed(String)
    case noVersionAvailable
    case versionAlreadyInstalled(String)
    case cannotDeleteCurrentVersion
    
    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg):
            return "Failed to download proxy: \(msg)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum verification failed: expected \(expected.prefix(16))..., got \(actual.prefix(16))..."
        case .extractionFailed(let msg):
            return "Failed to extract proxy: \(msg)"
        case .installationFailed(let msg):
            return "Failed to install proxy: \(msg)"
        case .compatibilityCheckFailed(let result):
            return "Compatibility check failed: \(result.description)"
        case .dryRunFailed(let msg):
            return "Dry-run failed: \(msg)"
        case .rollbackFailed(let msg):
            return "Rollback failed: \(msg)"
        case .noVersionAvailable:
            return "No compatible proxy version available"
        case .versionAlreadyInstalled(let version):
            return "Version \(version) is already installed"
        case .cannotDeleteCurrentVersion:
            return "Cannot delete the currently active version"
        }
    }
}
