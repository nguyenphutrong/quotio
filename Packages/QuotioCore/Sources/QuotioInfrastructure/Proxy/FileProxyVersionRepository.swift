@preconcurrency import Foundation
import Darwin
import QuotioApplication
import QuotioDomain

public actor FileProxyVersionRepository: ProxyVersionRepository {
    private static let binaryName = "CLIProxyAPI"

    private let fileManager: FileManager
    private let proxyDirectory: URL

    public init(
        proxyDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let proxyDirectory {
            self.proxyDirectory = proxyDirectory
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            self.proxyDirectory = appSupport.appendingPathComponent("Quotio/proxy")
        }
        try? fileManager.createDirectory(
            at: self.proxyDirectory,
            withIntermediateDirectories: true
        )
    }

    public func snapshot() -> ProxyVersionSnapshot {
        ProxyVersionSnapshot(
            currentBinaryPath: currentBinaryPath,
            expectedBinaryPath: currentSymlink.appendingPathComponent(Self.binaryName).path,
            currentVersion: currentVersion,
            installedVersions: listInstalledVersions()
        )
    }

    public func binaryPath(for version: String) -> String? {
        let path = upstreamDirectory
            .appendingPathComponent("v\(version)")
            .appendingPathComponent(Self.binaryName).path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    public func install(
        version: String,
        data: Data,
        assetName: String
    ) async throws -> InstalledProxyVersion {
        try fileManager.createDirectory(at: upstreamDirectory, withIntermediateDirectories: true)
        let versionDirectory = upstreamDirectory.appendingPathComponent("v\(version)")
        let destination = versionDirectory.appendingPathComponent(Self.binaryName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ProxyFailure.versionAlreadyInstalled(version)
        }
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)

        do {
            try extractAndInstall(data: data, assetName: assetName, destination: destination)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destination.path
            )
            signBinary(at: destination.path)
            return InstalledProxyVersion(
                version: version,
                path: destination.path,
                installedAt: Date(),
                isCurrent: false
            )
        } catch {
            try? fileManager.removeItem(at: versionDirectory)
            if let failure = error as? ProxyFailure { throw failure }
            throw ProxyFailure.installationFailed(String(describing: error))
        }
    }

    public func activate(version: String) throws {
        let versionDirectory = upstreamDirectory.appendingPathComponent("v\(version)")
        guard fileManager.fileExists(atPath: versionDirectory.path) else {
            throw ProxyFailure.installationFailed("Version \(version) is not installed")
        }

        let temporarySymlink = upstreamDirectory.appendingPathComponent(
            ".current-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporarySymlink) }
        try fileManager.createSymbolicLink(
            at: temporarySymlink,
            withDestinationURL: versionDirectory
        )
        let result = temporarySymlink.path.withCString { source in
            currentSymlink.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func delete(version: String) throws {
        guard version != currentVersion else {
            throw ProxyFailure.cannotDeleteCurrentVersion
        }
        let directory = upstreamDirectory.appendingPathComponent("v\(version)")
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    public func cleanup(keeping count: Int) {
        let versions = sortedVersionsKeepingCurrentFirst()
        let keepCount = max(count, 1)
        guard versions.count > keepCount else { return }
        for version in versions.dropFirst(keepCount) where !version.isCurrent {
            try? delete(version: version.version)
        }
    }

    public func versionsToDeleteAfterInstalling(keeping count: Int) -> [String] {
        let versions = sortedVersionsKeepingCurrentFirst()
        let keepCount = max(count, 1)
        let deleteCount = max(versions.count + 1 - keepCount, 0)
        guard deleteCount > 0 else { return [] }
        return versions.suffix(deleteCount)
            .filter { !$0.isCurrent }
            .map(\.version)
    }

    private var upstreamDirectory: URL {
        proxyDirectory.appendingPathComponent("upstream")
    }

    private var currentSymlink: URL {
        upstreamDirectory.appendingPathComponent("current")
    }

    private var currentBinaryPath: String? {
        let path = currentSymlink.appendingPathComponent(Self.binaryName).path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    private var currentVersion: String? {
        guard fileManager.fileExists(atPath: currentSymlink.path),
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: currentSymlink.path) else {
            return nil
        }
        let name = URL(fileURLWithPath: destination, relativeTo: proxyDirectory).lastPathComponent
        return name.hasPrefix("v") ? String(name.dropFirst()) : name
    }

    private func listInstalledVersions() -> [InstalledProxyVersion] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: upstreamDirectory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        ) else {
            return []
        }
        let activeVersion = currentVersion
        return contents.compactMap { url in
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            guard name != "current",
                  name.hasPrefix("v"),
                  fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            let path = url.appendingPathComponent(Self.binaryName).path
            guard fileManager.fileExists(atPath: path) else { return nil }
            let version = String(name.dropFirst())
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let installedAt = attributes?[.creationDate] as? Date ?? Date()
            return InstalledProxyVersion(
                version: version,
                path: path,
                installedAt: installedAt,
                isCurrent: version == activeVersion
            )
        }
        .sorted { $0.installedAt > $1.installedAt }
    }

    private func sortedVersionsKeepingCurrentFirst() -> [InstalledProxyVersion] {
        listInstalledVersions().sorted { lhs, rhs in
            if lhs.isCurrent { return true }
            if rhs.isCurrent { return false }
            return lhs.installedAt > rhs.installedAt
        }
    }

    private func extractAndInstall(data: Data, assetName: String, destination: URL) throws {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let downloadedFile = temporaryDirectory.appendingPathComponent(assetName)
        try data.write(to: downloadedFile)
        if assetName.hasSuffix(".tar.gz") || assetName.hasSuffix(".tgz") {
            try run(
                executable: "/usr/bin/tar",
                arguments: [
                    "-xzf", downloadedFile.path,
                    "-C", temporaryDirectory.path,
                    "--no-same-permissions",
                ],
                failure: "tar extraction failed"
            )
            try validateExtractedFiles(in: temporaryDirectory)
            guard let binary = try findBinary(in: temporaryDirectory) else {
                throw ProxyFailure.extractionFailed("Binary not found in archive")
            }
            try fileManager.copyItem(at: binary, to: destination)
        } else if assetName.hasSuffix(".zip") {
            try run(
                executable: "/usr/bin/unzip",
                arguments: ["-o", downloadedFile.path, "-d", temporaryDirectory.path],
                failure: "unzip extraction failed"
            )
            try validateExtractedFiles(in: temporaryDirectory)
            guard let binary = try findBinary(in: temporaryDirectory) else {
                throw ProxyFailure.extractionFailed("Binary not found in archive")
            }
            try fileManager.copyItem(at: binary, to: destination)
        } else {
            try fileManager.copyItem(at: downloadedFile, to: destination)
        }
    }

    private func validateExtractedFiles(in directory: URL) throws {
        let rootPath = directory.standardizedFileURL.path
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw ProxyFailure.extractionFailed(
                    "Archive contains path traversal: \(fileURL.lastPathComponent)"
                )
            }
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                let resolved = URL(
                    fileURLWithPath: destination,
                    relativeTo: fileURL.deletingLastPathComponent()
                ).standardizedFileURL.path
                guard resolved.hasPrefix(rootPath) else {
                    throw ProxyFailure.extractionFailed(
                        "Archive contains symlink escape: \(fileURL.lastPathComponent)"
                    )
                }
            }
        }
    }

    private func findBinary(in directory: URL) throws -> URL? {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExecutableKey]
        )
        let knownNames = ["cliproxyapi", "cli-proxy-api", "claude-code-proxy", "proxy"]
        if let known = contents.first(where: {
            knownNames.contains($0.lastPathComponent.lowercased())
        }) {
            return known
        }
        for item in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue, let found = try findBinary(in: item) {
                return found
            }
            if !isDirectory.boolValue,
               try item.resourceValues(forKeys: [.isExecutableKey]).isExecutable == true {
                let name = item.lastPathComponent.lowercased()
                if !name.hasSuffix(".sh") && !name.hasSuffix(".txt") && !name.hasSuffix(".md") {
                    return item
                }
            }
        }
        return nil
    }

    private func run(executable: String, arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProxyFailure.extractionFailed(failure)
        }
    }

    private func signBinary(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-f", "-s", "-", path]
        try? process.run()
        process.waitUntilExit()
    }
}
