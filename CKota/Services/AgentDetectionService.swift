//
//  AgentDetectionService.swift
//  CKota - Detect installed CLI agents
//

import Foundation

actor AgentDetectionService {
    private var cachedStatuses: [AgentStatus]?
    private var cacheTimestamp: Date?
    private let cacheValidity: TimeInterval = 60

    func detectAllAgents(forceRefresh: Bool = false) async -> [AgentStatus] {
        if !forceRefresh,
           let cached = cachedStatuses,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidity
        {
            return cached
        }

        let results = await withTaskGroup(of: AgentStatus.self) { group in
            for agent in CLIAgent.allCases {
                group.addTask {
                    await self.detectAgent(agent)
                }
            }

            var statuses: [AgentStatus] = []
            for await status in group {
                statuses.append(status)
            }
            return statuses.sorted { $0.agent.displayName < $1.agent.displayName }
        }

        cachedStatuses = results
        cacheTimestamp = Date()
        return results
    }

    func invalidateCache() {
        cachedStatuses = nil
        cacheTimestamp = nil
    }

    func detectAgent(_ agent: CLIAgent) async -> AgentStatus {
        let (installed, binaryPath) = await findBinary(names: agent.binaryNames)
        let version = installed ? await getVersion(binaryPath: binaryPath!) : nil
        let configured = installed ? await checkConfiguration(agent: agent) : false

        return AgentStatus(
            agent: agent,
            installed: installed,
            configured: configured,
            binaryPath: binaryPath,
            version: version,
            lastConfigured: configured ? getLastConfiguredDate(agent: agent) : nil
        )
    }

    private func findBinary(names: [String]) async -> (found: Bool, path: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        for name in names {
            let commonPaths = [
                // System paths
                "/usr/local/bin/\(name)",
                "/opt/homebrew/bin/\(name)",
                "/usr/bin/\(name)",
                // User local paths
                "\(home)/.local/bin/\(name)",
                // Package manager paths
                "\(home)/.cargo/bin/\(name)",
                "\(home)/.npm-global/bin/\(name)",
                "\(home)/.bun/bin/\(name)",
                // Tool-specific paths
                "\(home)/.opencode/bin/\(name)",
                "\(home)/.droid/bin/\(name)",
                // Node global paths
                "/usr/local/lib/node_modules/.bin/\(name)",
                "\(home)/.nvm/versions/node/*/bin/\(name)",
            ]

            for path in commonPaths {
                if FileManager.default.isExecutableFile(atPath: path) {
                    return (true, path)
                }
            }

            if let path = await whichCommand(name) {
                return (true, path)
            }
        }
        return (false, nil)
    }

    private func whichCommand(_ name: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [name]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty
                    {
                        continuation.resume(returning: path)
                        return
                    }
                }
            } catch {}
            continuation.resume(returning: nil)
        }
    }

    private func getVersion(binaryPath: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["--version"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let version = output
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .newlines)
                        .first ?? output
                    continuation.resume(returning: version)
                    return
                }
            } catch {}
            continuation.resume(returning: nil)
        }
    }

    private func checkConfiguration(agent: CLIAgent) async -> Bool {
        switch agent.configType {
        case .file, .both:
            checkConfigFiles(agent: agent)
        case .environment:
            UserDefaults.standard.bool(forKey: "agent.\(agent.rawValue).configured")
        }
    }

    private func checkConfigFiles(agent: CLIAgent) -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        for configPath in agent.configPaths {
            let expandedPath = configPath.replacingOccurrences(of: "~", with: home)

            if fileManager.fileExists(atPath: expandedPath) {
                if let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
                    if content.contains("127.0.0.1") || content.contains("localhost") || content
                        .contains("cliproxyapi")
                    {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func getLastConfiguredDate(agent: CLIAgent) -> Date? {
        UserDefaults.standard.object(forKey: "agent.\(agent.rawValue).lastConfigured") as? Date
    }

    func markAsConfigured(_ agent: CLIAgent) {
        UserDefaults.standard.set(true, forKey: "agent.\(agent.rawValue).configured")
        UserDefaults.standard.set(Date(), forKey: "agent.\(agent.rawValue).lastConfigured")
    }

    func clearConfiguredStatus(_ agent: CLIAgent) {
        UserDefaults.standard.removeObject(forKey: "agent.\(agent.rawValue).configured")
        UserDefaults.standard.removeObject(forKey: "agent.\(agent.rawValue).lastConfigured")
    }
}
