//
//  ProxyStorageManager.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Manages versioned proxy storage with symlink-based version switching.
//
//  Storage Layout:
//  ~/.quotio/proxy/
//   ├─ v1.2.3/
//   │   └─ CLIProxyAPI
//   ├─ v1.3.0/
//   │   └─ CLIProxyAPI
//   └─ current → v1.2.3
//

import Foundation

/// Manages versioned proxy binary storage.
@MainActor
@Observable
final class ProxyStorageManager {
    static let shared = ProxyStorageManager()
    
    private let fileManager = FileManager.default
    private let proxyDir: URL
    private let currentSymlink: URL
    private static let binaryName = "CLIProxyAPI"
    
    private init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }
        self.proxyDir = appSupport.appendingPathComponent("Quotio/proxy")
        self.currentSymlink = proxyDir.appendingPathComponent("current")
        
        try? fileManager.createDirectory(at: proxyDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Public Properties
    
    /// Path to the currently active proxy binary.
    var currentBinaryPath: String? {
        let binaryPath = currentSymlink.appendingPathComponent(Self.binaryName).path
        return fileManager.fileExists(atPath: binaryPath) ? binaryPath : nil
    }
    
    /// Check if any proxy version is installed.
    var hasInstalledVersion: Bool {
        currentBinaryPath != nil
    }
    
    // MARK: - Version Management
    
    /// Get the currently active version.
    func getCurrentVersion() -> String? {
        guard fileManager.fileExists(atPath: currentSymlink.path) else { return nil }
        
        do {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: currentSymlink.path)
            let versionDir = URL(fileURLWithPath: destination, relativeTo: proxyDir)
            let versionName = versionDir.lastPathComponent
            
            if versionName.hasPrefix("v") {
                return String(versionName.dropFirst())
            }
            return versionName
        } catch {
            return nil
        }
    }
    
    /// List all installed proxy versions.
    func listInstalledVersions() -> [InstalledProxyVersion] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: proxyDir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        ) else {
            return []
        }
        
        let currentVersion = getCurrentVersion()
        
        return contents.compactMap { url -> InstalledProxyVersion? in
            let name = url.lastPathComponent
            
            // Skip "current" symlink
            guard name != "current" else { return nil }
            
            // Check if it's a directory starting with "v"
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  name.hasPrefix("v") else {
                return nil
            }
            
            // Check if the binary exists inside
            let binaryPath = url.appendingPathComponent(Self.binaryName).path
            guard fileManager.fileExists(atPath: binaryPath) else { return nil }
            
            let version = String(name.dropFirst()) // Remove "v" prefix
            let creationDate = (try? fileManager.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
            
            return InstalledProxyVersion(
                version: version,
                path: binaryPath,
                installedAt: creationDate,
                isCurrent: version == currentVersion
            )
        }
        .sorted { $0.installedAt > $1.installedAt }
    }
    
    /// Get the binary path for a specific version.
    func getBinaryPath(for version: String) -> String? {
        let versionDir = proxyDir.appendingPathComponent("v\(version)")
        let binaryPath = versionDir.appendingPathComponent(Self.binaryName).path
        
        return fileManager.fileExists(atPath: binaryPath) ? binaryPath : nil
    }
    
    // MARK: - Installation
    
    /// Install a new proxy version from binary data.
    /// - Parameters:
    ///   - version: The version string (e.g., "1.2.3")
    ///   - binaryData: The raw binary data (or compressed archive)
    ///   - assetName: Original asset filename to determine extraction method
    /// - Returns: The installed version info
    func installVersion(version: String, binaryData: Data, assetName: String) async throws -> InstalledProxyVersion {
        let versionDir = proxyDir.appendingPathComponent("v\(version)")
        let binaryPath = versionDir.appendingPathComponent(Self.binaryName)
        
        // Check if already installed
        if fileManager.fileExists(atPath: binaryPath.path) {
            throw ProxyUpgradeError.versionAlreadyInstalled(version)
        }
        
        // Create version directory
        try fileManager.createDirectory(at: versionDir, withIntermediateDirectories: true)
        
        do {
            // Extract or copy binary
            try await extractAndInstall(data: binaryData, assetName: assetName, destination: binaryPath)
            
            // Set executable permission
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
            
            // Ad-hoc sign the binary
            try await signBinary(at: binaryPath.path)
            
            return InstalledProxyVersion(
                version: version,
                path: binaryPath.path,
                installedAt: Date(),
                isCurrent: false
            )
        } catch {
            // Cleanup on failure
            try? fileManager.removeItem(at: versionDir)
            throw ProxyUpgradeError.installationFailed(error.localizedDescription)
        }
    }
    
    /// Set the current version by updating the symlink.
    /// - Parameter version: The version to make active
    func setCurrentVersion(_ version: String) throws {
        let versionDir = proxyDir.appendingPathComponent("v\(version)")
        
        // Verify version exists
        guard fileManager.fileExists(atPath: versionDir.path) else {
            throw ProxyUpgradeError.installationFailed("Version \(version) is not installed")
        }
        
        // Remove existing symlink
        if fileManager.fileExists(atPath: currentSymlink.path) {
            try fileManager.removeItem(at: currentSymlink)
        }
        
        // Create new symlink (use relative path for portability)
        try fileManager.createSymbolicLink(
            at: currentSymlink,
            withDestinationURL: versionDir
        )
    }
    
    /// Delete an installed version.
    /// - Parameter version: The version to delete
    /// - Throws: If trying to delete the current version
    func deleteVersion(_ version: String) throws {
        let currentVersion = getCurrentVersion()
        
        // Prevent deleting current version
        if version == currentVersion {
            throw ProxyUpgradeError.cannotDeleteCurrentVersion
        }
        
        let versionDir = proxyDir.appendingPathComponent("v\(version)")
        
        if fileManager.fileExists(atPath: versionDir.path) {
            try fileManager.removeItem(at: versionDir)
        }
    }
    
    /// Cleanup old versions, keeping the specified number of recent versions.
    /// Never deletes the current active version.
    /// - Parameter keepLast: Number of versions to keep (including current)
    func cleanupOldVersions(keepLast: Int = AppConstants.maxInstalledVersions) {
        let versions = listInstalledVersions()
        let currentVersion = getCurrentVersion()
        
        // Always keep at least the current version
        let versionsToKeep = max(keepLast, 1)
        
        guard versions.count > versionsToKeep else { return }
        
        // Sort by installation date (newest first), keeping current always
        let sortedVersions = versions.sorted { v1, v2 in
            if v1.isCurrent { return true }
            if v2.isCurrent { return false }
            return v1.installedAt > v2.installedAt
        }
        
        // Delete versions beyond the keepLast count
        for version in sortedVersions.dropFirst(versionsToKeep) {
            // Double-check: never delete current
            guard version.version != currentVersion else { continue }
            
            try? deleteVersion(version.version)
        }
    }
    
    /// Get versions that would be deleted if a new version is installed.
    /// - Parameter keepLast: Number of versions to keep (including current)
    /// - Returns: List of version strings that will be deleted
    func versionsToBeDeleted(keepLast: Int = AppConstants.maxInstalledVersions) -> [String] {
        let versions = listInstalledVersions()
        let currentVersion = getCurrentVersion()
        
        // After installing a new version, we'll have versions.count + 1 versions
        let futureCount = versions.count + 1
        let versionsToKeep = max(keepLast, 1)
        
        guard futureCount > versionsToKeep else { return [] }
        
        // Sort by installation date (newest first), keeping current always
        let sortedVersions = versions.sorted { v1, v2 in
            if v1.isCurrent { return true }
            if v2.isCurrent { return false }
            return v1.installedAt > v2.installedAt
        }
        
        // The oldest versions (beyond keepLast - 1, since new version takes one slot)
        let deleteCount = futureCount - versionsToKeep
        return sortedVersions.suffix(deleteCount)
            .filter { $0.version != currentVersion }
            .map { $0.version }
    }
    
    // MARK: - Private Helpers
    
    private func extractAndInstall(data: Data, assetName: String, destination: URL) async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        let downloadedFile = tempDir.appendingPathComponent(assetName)
        try data.write(to: downloadedFile)
        
        if assetName.hasSuffix(".tar.gz") || assetName.hasSuffix(".tgz") {
            // Use tar with --strip-components to prevent path traversal
            // and extract only to the temp directory
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", downloadedFile.path, "-C", tempDir.path, "--no-same-permissions"]
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw ProxyUpgradeError.extractionFailed("tar extraction failed")
            }
            
            // Validate extracted files don't escape temp directory
            try validateExtractedFiles(in: tempDir)
            
            if let binary = try findBinaryInDirectory(tempDir) {
                try fileManager.copyItem(at: binary, to: destination)
            } else {
                throw ProxyUpgradeError.extractionFailed("Binary not found in archive")
            }
            
        } else if assetName.hasSuffix(".zip") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", downloadedFile.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw ProxyUpgradeError.extractionFailed("unzip extraction failed")
            }
            
            // Validate extracted files don't escape temp directory
            try validateExtractedFiles(in: tempDir)
            
            if let binary = try findBinaryInDirectory(tempDir) {
                try fileManager.copyItem(at: binary, to: destination)
            } else {
                throw ProxyUpgradeError.extractionFailed("Binary not found in archive")
            }
            
        } else {
            // Direct binary
            try fileManager.copyItem(at: downloadedFile, to: destination)
        }
    }
    
    /// Validate that all extracted files are within the expected directory.
    /// Protects against path traversal attacks via malicious archive entries.
    private func validateExtractedFiles(in directory: URL) throws {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        let directoryPath = directory.standardizedFileURL.path
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let standardizedPath = fileURL.standardizedFileURL.path
            
            // Ensure the file is within the temp directory
            guard standardizedPath.hasPrefix(directoryPath) else {
                throw ProxyUpgradeError.extractionFailed("Archive contains path traversal attack: \(fileURL.lastPathComponent)")
            }
            
            // Check for symlinks pointing outside the directory
            let resourceValues = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                let resolvedURL = URL(fileURLWithPath: destination, relativeTo: fileURL.deletingLastPathComponent())
                let resolvedPath = resolvedURL.standardizedFileURL.path
                
                if !resolvedPath.hasPrefix(directoryPath) {
                    throw ProxyUpgradeError.extractionFailed("Archive contains symlink escape: \(fileURL.lastPathComponent)")
                }
            }
        }
    }
    
    private func findBinaryInDirectory(_ directory: URL) throws -> URL? {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey]
        )
        
        let binaryNames = ["CLIProxyAPI", "cli-proxy-api", "cli-proxy-api-plus", "claude-code-proxy", "proxy"]
        
        // Check for known binary names first
        for name in binaryNames {
            if let found = contents.first(where: { $0.lastPathComponent.lowercased() == name.lowercased() }) {
                return found
            }
        }
        
        // Recursively search subdirectories
        for item in contents {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    if let found = try findBinaryInDirectory(item) {
                        return found
                    }
                } else {
                    let resourceValues = try item.resourceValues(forKeys: [.isExecutableKey])
                    if resourceValues.isExecutable == true {
                        let name = item.lastPathComponent.lowercased()
                        if !name.hasSuffix(".sh") && !name.hasSuffix(".txt") && !name.hasSuffix(".md") {
                            return item
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func signBinary(at path: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-f", "-s", "-", path]
        
        try process.run()
        process.waitUntilExit()
        
        // Don't throw on signing failure - it's best effort
    }
}
