//
//  ShellProfileManager.swift
//  CKota - Manage shell profile modifications
//

import Foundation

actor ShellProfileManager {
    private let fileManager = FileManager.default

    func detectShell() -> ShellType {
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            if shell.contains("zsh") { return .zsh }
            if shell.contains("bash") { return .bash }
            if shell.contains("fish") { return .fish }
        }
        return .zsh
    }

    func getProfilePath(for shell: ShellType) -> String {
        shell.profilePath
    }

    func addToProfile(
        shell: ShellType,
        configuration: String,
        agent: CLIAgent
    ) async throws {
        let profilePath = getProfilePath(for: shell)
        let marker = "# CLIProxyAPI Configuration for \(agent.displayName)"
        let endMarker = "# End CLIProxyAPI Configuration for \(agent.displayName)"

        var content: String
        if fileManager.fileExists(atPath: profilePath) {
            content = try String(contentsOfFile: profilePath, encoding: .utf8)

            if let startRange = content.range(of: marker),
               let endRange = content.range(of: endMarker)
            {
                let fullRange = startRange.lowerBound ..< content.index(after: endRange.upperBound)
                content.removeSubrange(fullRange)
            }
        } else {
            content = ""
        }

        let newConfig = """

        \(marker)
        \(configuration)
        \(endMarker)
        """

        content.append(newConfig)

        try content.write(toFile: profilePath, atomically: true, encoding: .utf8)
    }

    func removeFromProfile(
        shell: ShellType,
        agent: CLIAgent
    ) async throws {
        let profilePath = getProfilePath(for: shell)
        let marker = "# CLIProxyAPI Configuration for \(agent.displayName)"
        let endMarker = "# End CLIProxyAPI Configuration for \(agent.displayName)"

        guard fileManager.fileExists(atPath: profilePath) else { return }

        var content = try String(contentsOfFile: profilePath, encoding: .utf8)

        if let startRange = content.range(of: marker),
           let endRange = content.range(of: endMarker)
        {
            var startIndex = startRange.lowerBound
            if startIndex > content.startIndex {
                let prevIndex = content.index(before: startIndex)
                if content[prevIndex] == "\n" {
                    startIndex = prevIndex
                }
            }

            var endIndex = endRange.upperBound
            if endIndex < content.endIndex {
                let nextIndex = content.index(after: endIndex)
                if nextIndex <= content.endIndex, content[endIndex] == "\n" {
                    endIndex = nextIndex
                }
            }

            content.removeSubrange(startIndex ..< endIndex)
            try content.write(toFile: profilePath, atomically: true, encoding: .utf8)
        }
    }

    func isConfiguredInProfile(
        shell: ShellType,
        agent: CLIAgent
    ) -> Bool {
        let profilePath = getProfilePath(for: shell)
        let marker = "# CLIProxyAPI Configuration for \(agent.displayName)"

        guard let content = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
            return false
        }

        return content.contains(marker)
    }

    func createBackup(shell: ShellType) throws -> String {
        let profilePath = getProfilePath(for: shell)
        let backupPath = "\(profilePath).backup.\(Int(Date().timeIntervalSince1970))"

        if fileManager.fileExists(atPath: profilePath) {
            try fileManager.copyItem(atPath: profilePath, toPath: backupPath)
        }

        return backupPath
    }
}
