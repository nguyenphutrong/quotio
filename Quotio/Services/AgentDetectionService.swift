//
//  AgentDetectionService.swift
//  Quotio - Detect installed CLI agents
//

import Foundation

actor AgentDetectionService {
    private var cachedStatuses: [AgentStatus]?
    private var cacheTimestamp: Date?
    private let cacheValidity: TimeInterval = 60
    
    // MARK: - Common Binary Paths
    
    /// Common CLI binary paths to search
    /// NOTE: Only checks file existence (metadata), does NOT read file content
    /// This is different from IDE scanning which reads auth/config data
    private static let commonBinaryPaths: [String] = [
        // System paths
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        // User local
        "~/.local/bin",
        // Package managers
        "~/.cargo/bin",          // Rust/Cargo
        "~/.bun/bin",            // Bun (gemini-cli)
        "~/.deno/bin",           // Deno
        "~/.npm-global/bin",     // npm global
        // Tool-specific
        "~/.opencode/bin",       // OpenCode
        "~/.warp/bin",           // Warp (if any)
        // Version managers (static shim paths)
        "~/.volta/bin",          // Volta
        "~/.asdf/shims",         // asdf
        "~/.local/share/mise/shims", // mise
    ]
    
    func detectAllAgents(forceRefresh: Bool = false) async -> [AgentStatus] {
        if !forceRefresh,
           let cached = cachedStatuses,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidity {
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
        // NOTE: --version is intentionally not fetched here. It is unused in the UI and
        // spawning the CLI (especially Node-based ones) costs hundreds of ms per agent.
        // Callers that need the version can invoke getVersion(binaryPath:) lazily.
        let configured = installed ? await checkConfiguration(agent: agent) : false

        return AgentStatus(
            agent: agent,
            installed: installed,
            configured: configured,
            binaryPath: binaryPath,
            version: nil,
            lastConfigured: configured ? getLastConfiguredDate(agent: agent) : nil
        )
    }
    
    /// Find binary using 'which' command + fallback to common paths
    private func findBinary(names: [String]) async -> (found: Bool, path: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        for name in names {
            // 1. Try which command first (works if PATH is set correctly)
            // Note: May not work in GUI apps due to limited PATH inheritance
            if let path = await whichCommand(name) {
                return (true, path)
            }
            
            // 2. Check static common paths
            // NOTE: Only checks file existence (metadata), does NOT read file content
            for basePath in Self.commonBinaryPaths {
                let expandedBase = basePath.replacingOccurrences(of: "~", with: home)
                let fullPath = "\(expandedBase)/\(name)"
                if FileManager.default.isExecutableFile(atPath: fullPath) {
                    return (true, fullPath)
                }
            }
            
            // 3. Check version manager paths (nvm, fnm - versioned directories)
            for path in getVersionManagerPaths(name: name, home: home) {
                if FileManager.default.isExecutableFile(atPath: path) {
                    return (true, path)
                }
            }
        }
        return (false, nil)
    }
    
    /// Get paths from version managers that use versioned subdirectories
    /// Sorted descending to prefer newer versions
    private func getVersionManagerPaths(name: String, home: String) -> [String] {
        var paths: [String] = []
        let fileManager = FileManager.default
        
        // nvm: ~/.nvm/versions/node/v*/bin/
        let nvmBase = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmBase) {
            for version in versions.sorted().reversed() {
                paths.append("\(nvmBase)/\(version)/bin/\(name)")
            }
        }
        
        // fnm: $XDG_DATA_HOME/fnm (defaults to ~/.local/share/fnm), then legacy ~/.fnm
        let xdgDataHome: String
        if let envValue = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !envValue.isEmpty {
            xdgDataHome = envValue
        } else {
            xdgDataHome = "\(home)/.local/share"
        }
        let fnmPaths = [
            "\(xdgDataHome)/fnm/node-versions",
            "\(home)/.fnm/node-versions"  // legacy path
        ]

        for fnmBase in fnmPaths {
            if let versions = try? fileManager.contentsOfDirectory(atPath: fnmBase), !versions.isEmpty {
                for version in versions.sorted().reversed() {
                    paths.append("\(fnmBase)/\(version)/installation/bin/\(name)")
                }
                break  // found fnm installation, skip legacy path
            }
        }
        
        return paths
    }
    
    private func whichCommand(_ name: String) async -> String? {
        // Use terminationHandler instead of waitUntilExit so we do NOT block the
        // actor's executor. Blocking here would serialize every detectAgent() call
        // in the TaskGroup and defeat the concurrency entirely.
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [name]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { proc in
                defer { try? pipe.fileHandleForReading.close() }
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                // run() failed -> terminationHandler will not fire. Detach it to
                // make the single-resume contract explicit, then resume with nil.
                process.terminationHandler = nil
                try? pipe.fileHandleForReading.close()
                continuation.resume(returning: nil)
            }
        }
    }
    
    /// Fetch `<binary> --version` output. Not called during the initial scan
    /// because (a) the output is not surfaced in the UI and (b) Node-based CLIs
    /// take hundreds of ms to start. Exposed for callers that want it lazily.
    func getVersion(binaryPath: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["--version"]
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { _ in
                defer { try? pipe.fileHandleForReading.close() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                let version = output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .first ?? output
                continuation.resume(returning: version.isEmpty ? nil : version)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? pipe.fileHandleForReading.close()
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func checkConfiguration(agent: CLIAgent) async -> Bool {
        if agent == .copilotCLI {
            return checkCopilotCLIConfiguration()
        }

        switch agent.configType {
        case .file, .both:
            return checkConfigFiles(agent: agent)
        case .environment:
            return UserDefaults.standard.bool(forKey: "agent.\(agent.rawValue).configured")
        }
    }

    private func checkCopilotCLIConfiguration() -> Bool {
        let shellPaths = ShellType.allCases.map(\.profilePath)
        let marker = "# CLIProxyAPI Configuration for \(CLIAgent.copilotCLI.displayName)"

        for shellPath in shellPaths {
            guard let content = try? String(contentsOfFile: shellPath, encoding: .utf8) else { continue }
            if content.contains(marker) || content.contains("COPILOT_PROVIDER_BASE_URL") {
                return true
            }
        }

        return false
    }
    
    private func checkConfigFiles(agent: CLIAgent) -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        
        for configPath in agent.configPaths {
            let expandedPath = configPath.replacingOccurrences(of: "~", with: home)
            
            if fileManager.fileExists(atPath: expandedPath) {
                if let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
                    if content.contains("127.0.0.1") || content.contains("localhost") || content.contains("cliproxyapi") {
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
