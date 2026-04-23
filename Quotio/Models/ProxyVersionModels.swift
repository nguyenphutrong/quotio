//
//  ProxyVersionModels.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Models for managed proxy versioning and compatibility checking.
//

import Foundation

// MARK: - Proxy Binary Source

nonisolated enum ProxyBinarySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case plusLocal
    case upstream

    static let userDefaultsKey = "selectedProxyBinarySource"
    static let explicitSelectionDefaultsKey = "hasExplicitProxyBinarySourceSelection"
    static let plusLocalVersion = "6.9.28-0"
    static let plusLocalSHA256 = "a722885ab3c0cea5535ee69a86220d35c4f95ee7656e009d872d24de2910acf0"
    static let plusLocalBinaryName = "cli-proxy-api-plus"
    static let plusLocalResourceSubdirectory = "Proxy"

    var id: String { rawValue }

    var storageDirectoryName: String {
        switch self {
        case .plusLocal: return "plus"
        case .upstream: return "upstream"
        }
    }

    var displayName: String {
        switch self {
        case .plusLocal:
            return "CLIProxyAPIPlus"
        case .upstream:
            return "CLIProxyAPI"
        }
    }

    var shortDescription: String {
        switch self {
        case .plusLocal:
            return "Bundled 6.9.28-0 with legacy compatibility"
        case .upstream:
            return "Latest maintained upstream releases"
        }
    }

    var selectionDescription: String {
        switch self {
        case .plusLocal:
            return "CLIProxyAPIPlus (bundled 6.9.28-0)"
        case .upstream:
            return "CLIProxyAPI (latest upstream)"
        }
    }

    var detailDescription: String {
        switch self {
        case .plusLocal:
            return "Preserves legacy Copilot and Kiro compatibility."
        case .upstream:
            return "Actively maintained upstream releases."
        }
    }

    var installActionTitle: String {
        switch self {
        case .plusLocal:
            return "Install CLIProxyAPIPlus"
        case .upstream:
            return "Install CLIProxyAPI"
        }
    }

    var notInstalledTitle: String {
        switch self {
        case .plusLocal:
            return "CLIProxyAPIPlus Not Installed"
        case .upstream:
            return "CLIProxyAPI Not Installed"
        }
    }

    var installDescription: String {
        switch self {
        case .plusLocal:
            return "Install the bundled CLIProxyAPIPlus binary to continue."
        case .upstream:
            return "Install CLIProxyAPI to continue."
        }
    }

    var githubRepo: String? {
        switch self {
        case .plusLocal:
            return nil
        case .upstream:
            return "router-for-me/CLIProxyAPI"
        }
    }

    var releasesFeedURL: String? {
        switch self {
        case .plusLocal:
            return nil
        case .upstream:
            return "https://github.com/router-for-me/CLIProxyAPI/releases.atom"
        }
    }

    var installedVersionDefaultsKey: String {
        "installedProxyVersion_\(rawValue)"
    }

    var notificationVersionKey: String {
        "notifiedCLIProxyVersion_\(rawValue)"
    }

    var legacyAuthWarning: String? {
        switch self {
        case .plusLocal:
            return nil
        case .upstream:
            return "Copilot and Kiro auth flows may not work with the upstream CLIProxyAPI binary."
        }
    }

    var installHint: String {
        switch self {
        case .plusLocal:
            return "CLIProxyAPIPlus bundled binary is unavailable. Reinstall Quotio or restore the bundled proxy resource."
        case .upstream:
            return "CLIProxyAPI upstream binary is not installed. Open Settings and install a release."
        }
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
    
    var id: String { "\(source.rawValue):\(version)" }
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
