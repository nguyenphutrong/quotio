//
//  AntigravityVersionDetector.swift
//  Quotio
//
//  Detects Antigravity IDE version from Info.plist to determine
//  which protobuf injection format to use.
//  >= 1.16.5: new format (antigravityUnifiedStateSync.oauthToken)
//  <  1.16.5: old format (jetskiStateSync.agentManagerInitState)
//

import AppKit
import Foundation

/// Detects installed Antigravity IDE version for format-aware token injection
nonisolated enum AntigravityVersionDetector {
    
    // MARK: - Types
    
    struct Version: Sendable {
        let shortVersion: String
        let bundleVersion: String
    }
    
    enum VersionFormat: Sendable {
        case oldFormat      // < 1.16.5: jetskiStateSync.agentManagerInitState
        case newFormat      // >= 1.16.5: antigravityUnifiedStateSync.oauthToken
        case unknown        // Version detection failed — use dual fallback
    }
    
    // MARK: - Version Threshold
    
    private static let newFormatThreshold = "1.16.5"
    
    // MARK: - App Paths
    
    /// Known locations for Antigravity.app on macOS
    private static let appSearchPaths: [String] = [
        "/Applications/Antigravity.app",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity.app").path
    ]
    
    /// Bundle identifiers for Antigravity IDE
    private static let bundleIdentifiers = [
        "com.google.antigravity",
        "com.todesktop.230313mzl4w4u92"
    ]
    
    // MARK: - Public API
    
    /// Detect the installed Antigravity IDE version
    static func detectVersion() -> Version? {
        // Strategy 1: Find .app bundle directly and read Info.plist
        for path in appSearchPaths {
            if let version = readVersionFromApp(at: path) {
                return version
            }
        }
        
        // Strategy 2: Find via bundle identifier (NSWorkspace)
        for bundleId in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               let version = readVersionFromApp(at: url.path) {
                return version
            }
        }
        
        return nil
    }
    
    /// Determine which injection format to use
    static func detectFormat() -> VersionFormat {
        guard let version = detectVersion() else {
            Log.warning("Antigravity version detection failed, will use dual-format fallback")
            return .unknown
        }
        
        Log.debug("Detected Antigravity version: \(version.shortVersion)")
        
        if isNewVersion(version) {
            return .newFormat
        } else {
            return .oldFormat
        }
    }
    
    /// Check if version >= 1.16.5
    static func isNewVersion(_ version: Version) -> Bool {
        compareVersion(version.shortVersion, newFormatThreshold) != .orderedAscending
    }
    
    // MARK: - Private Helpers
    
    /// Read version info from an Antigravity.app bundle path
    private static func readVersionFromApp(at appPath: String) -> Version? {
        // Navigate to .app bundle if we got an executable path
        var bundlePath = appPath
        if let range = appPath.range(of: ".app") {
            bundlePath = String(appPath[appPath.startIndex..<range.upperBound])
            // Remove trailing slash if any after .app
            if bundlePath.hasSuffix("/") {
                bundlePath = String(bundlePath.dropLast())
            }
        }
        
        let infoPlistPath = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        let infoPlistURL = URL(fileURLWithPath: infoPlistPath)
        
        guard FileManager.default.fileExists(atPath: infoPlistPath),
              let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        
        guard let shortVersion = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        
        let bundleVersion = (plist["CFBundleVersion"] as? String) ?? shortVersion
        
        return Version(shortVersion: shortVersion, bundleVersion: bundleVersion)
    }
    
    /// Compare two semantic version strings (e.g., "1.16.5" vs "1.16.4")
    /// Returns ComparisonResult: .orderedAscending if v1 < v2, etc.
    private static func compareVersion(_ v1: String, _ v2: String) -> ComparisonResult {
        let parts1 = v1.split(separator: ".").compactMap { UInt($0) }
        let parts2 = v2.split(separator: ".").compactMap { UInt($0) }
        
        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        
        return .orderedSame
    }
}
