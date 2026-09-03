import Foundation
import QuotioDomain

public struct AgentFileWrite: Sendable {
    public let path: String
    public let data: Data
    public let permissions: Int?

    public init(path: String, data: Data, permissions: Int? = nil) {
        self.path = path
        self.data = data
        self.permissions = permissions
    }
}

public actor AgentFileStore {
    public nonisolated let homeDirectory: String

    private struct OriginalFile {
        let data: Data
        let permissions: Int?
    }

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let beforeWrite: @Sendable (_ path: String, _ index: Int) throws -> Void

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: @escaping @Sendable () -> Date = Date.init,
        beforeWrite: @escaping @Sendable (_ path: String, _ index: Int) throws -> Void = { _, _ in }
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = FileManager()
        self.now = now
        self.beforeWrite = beforeWrite
    }

    public nonisolated func path(_ tildePath: String) -> String {
        guard tildePath.hasPrefix("~") else { return tildePath }
        return homeDirectory + tildePath.dropFirst()
    }

    public func exists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path) && !isSymbolicLink(path)
    }

    public func data(at path: String) -> Data? {
        guard !isSymbolicLink(path) else { return nil }
        return fileManager.contents(atPath: path)
    }

    public func string(at path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        try refuseSymbolicLink(path)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    public func apply(_ writes: [AgentFileWrite]) throws -> [String: String] {
        var originals: [String: OriginalFile] = [:]
        var createdPaths = Set<String>()
        var backups: [String: String] = [:]

        for write in writes {
            try refuseSymbolicLink(write.path)
            if let originalData = fileManager.contents(atPath: write.path) {
                let permissions = try permissions(at: write.path)
                originals[write.path] = OriginalFile(data: originalData, permissions: permissions)
                if let backup = try backupIfPresent(write.path) {
                    backups[write.path] = backup
                }
            } else {
                createdPaths.insert(write.path)
            }
        }

        do {
            for (index, write) in writes.enumerated() {
                try beforeWrite(write.path, index)
                let directory = (write.path as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try write.data.write(to: URL(fileURLWithPath: write.path), options: .atomic)

                let desiredPermissions = write.permissions ?? originals[write.path]?.permissions
                if let desiredPermissions {
                    try fileManager.setAttributes(
                        [.posixPermissions: desiredPermissions],
                        ofItemAtPath: write.path
                    )
                }
            }
            return backups
        } catch {
            let originalError = error
            do {
                for write in writes.reversed() {
                    if let original = originals[write.path] {
                        try original.data.write(to: URL(fileURLWithPath: write.path), options: .atomic)
                        if let permissions = original.permissions {
                            try fileManager.setAttributes(
                                [.posixPermissions: permissions],
                                ofItemAtPath: write.path
                            )
                        }
                    } else if createdPaths.contains(write.path), fileManager.fileExists(atPath: write.path) {
                        try fileManager.removeItem(atPath: write.path)
                    }
                }
            } catch let rollbackError {
                throw AgentFileStoreError.rollbackFailed(
                    operation: originalError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw originalError
        }
    }

    public func backupIfPresent(_ path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        try refuseSymbolicLink(path)

        var timestamp = Int(now().timeIntervalSince1970)
        var backupPath = "\(path).backup.\(timestamp)"
        while fileManager.fileExists(atPath: backupPath) {
            timestamp += 1
            backupPath = "\(path).backup.\(timestamp)"
        }
        try fileManager.copyItem(atPath: path, toPath: backupPath)
        return backupPath
    }

    public func listBackups(for agent: CLIAgent) -> [AgentBackupFile] {
        var backups: [AgentBackupFile] = []

        for configuredPath in agent.configPaths {
            let expandedPath = path(configuredPath)
            let directory = (expandedPath as NSString).deletingLastPathComponent
            let filename = (expandedPath as NSString).lastPathComponent
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }

            for file in contents where file.hasPrefix(filename + ".backup.") {
                let backupPath = "\(directory)/\(file)"
                guard !isSymbolicLink(backupPath) else { continue }
                guard let timestampText = file.components(separatedBy: ".backup.").last,
                      let timestamp = Double(timestampText) else { continue }
                backups.append(AgentBackupFile(
                    path: backupPath,
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    agent: agent
                ))
            }
        }

        return backups.sorted { $0.timestamp > $1.timestamp }
    }

    public func restore(_ backup: AgentBackupFile) throws {
        try refuseSymbolicLink(backup.path)
        guard let marker = backup.path.range(of: ".backup.", options: .backwards) else {
            throw AgentFileStoreError.invalidBackupPath(backup.path)
        }
        let originalPath = String(backup.path[..<marker.lowerBound])
        let backupData = try Data(contentsOf: URL(fileURLWithPath: backup.path))
        let backupPermissions = try permissions(at: backup.path)
        _ = try apply([
            AgentFileWrite(
                path: originalPath,
                data: backupData,
                permissions: backupPermissions
            ),
        ])
    }

    private func permissions(at path: String) throws -> Int? {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func refuseSymbolicLink(_ path: String) throws {
        if isSymbolicLink(path) {
            throw AgentFileStoreError.symbolicLinkRefused(path)
        }
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

public enum AgentFileStoreError: LocalizedError, Equatable, Sendable {
    case invalidBackupPath(String)
    case symbolicLinkRefused(String)
    case rollbackFailed(operation: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBackupPath(let path):
            return "Invalid agent backup path: \(path)"
        case .symbolicLinkRefused(let path):
            return "Refusing to follow symbolic link at agent configuration path: \(path)"
        case .rollbackFailed(let operation, let rollback):
            return "The write failed (\(operation)) and rollback also failed (\(rollback))."
        }
    }
}
