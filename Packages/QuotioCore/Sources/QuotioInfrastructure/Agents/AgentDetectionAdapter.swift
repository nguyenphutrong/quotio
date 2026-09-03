import Foundation
import QuotioApplication
import QuotioDomain

extension CLIAgent {
    var binaryNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .codexCLI: return ["codex"]
        case .ampCLI: return ["amp"]
        case .openCode: return ["opencode", "oc"]
        case .factoryDroid: return ["droid", "factory-droid"]
        }
    }

    var configPaths: [String] {
        switch self {
        case .claudeCode: return ["~/.claude/settings.json"]
        case .codexCLI: return ["~/.codex/config.toml", "~/.codex/auth.json"]
        case .ampCLI: return ["~/.config/amp/settings.json", "~/.local/share/amp/secrets.json"]
        case .openCode: return ["~/.config/opencode/opencode.json"]
        case .factoryDroid: return ["~/.factory/config.json"]
        }
    }
}

public struct AgentBinaryInstallationProbe: Sendable {
    public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> String?

    private static let commonBinaryPaths = [
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "~/.local/bin",
        "~/.cargo/bin", "~/.bun/bin", "~/.deno/bin", "~/.npm-global/bin",
        "~/.opencode/bin", "~/.warp/bin", "~/.volta/bin", "~/.asdf/shims",
        "~/.local/share/mise/shims",
    ]

    private let homeDirectory: String
    private let environment: [String: String]
    private let commandRunner: CommandRunner

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: @escaping CommandRunner = AgentDetectionAdapter.runCommand
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.commandRunner = commandRunner
    }

    public func isInstalled(_ agent: CLIAgent) -> Bool {
        path(for: agent) != nil
    }

    public func isInstalled(binaryName: String) -> Bool {
        path(forBinaryName: binaryName) != nil
    }

    public func path(for agent: CLIAgent) -> String? {
        for name in agent.binaryNames {
            if let path = path(forBinaryName: name) { return path }
        }
        return nil
    }

    private func path(forBinaryName name: String) -> String? {
        let fileManager = FileManager()
        if let path = commandRunner("/usr/bin/which", [name])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        for basePath in Self.commonBinaryPaths {
            let path = expand(basePath) + "/" + name
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        for path in versionManagerPaths(name: name, fileManager: fileManager)
        where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func versionManagerPaths(name: String, fileManager: FileManager) -> [String] {
        var paths: [String] = []
        let nvmBase = homeDirectory + "/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmBase) {
            paths += versions.sorted(by: >).map { nvmBase + "/" + $0 + "/bin/" + name }
        }
        let xdgDataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory + "/.local/share"
        for base in [xdgDataHome + "/fnm/node-versions", homeDirectory + "/.fnm/node-versions"] {
            if let versions = try? fileManager.contentsOfDirectory(atPath: base), !versions.isEmpty {
                paths += versions.sorted(by: >).map { base + "/" + $0 + "/installation/bin/" + name }
                break
            }
        }
        return paths
    }

    private func expand(_ path: String) -> String {
        path.hasPrefix("~") ? homeDirectory + path.dropFirst() : path
    }
}

public actor CLIToolInstallationProbe: CLIToolInstallationProbing {
    private let probe: AgentBinaryInstallationProbe

    public init(probe: AgentBinaryInstallationProbe = AgentBinaryInstallationProbe()) {
        self.probe = probe
    }

    public func isInstalled(binaryName: String) -> Bool {
        probe.isInstalled(binaryName: binaryName)
    }
}

public actor AgentDetectionAdapter: AgentDetecting {
    public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> String?

    private let homeDirectory: String
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let commandRunner: CommandRunner
    private let installationProbe: AgentBinaryInstallationProbe
    private var cachedStatuses: [AgentStatus]?
    private var cacheTimestamp: Date?

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultsSuiteName: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        commandRunner: @escaping CommandRunner = AgentDetectionAdapter.runCommand
    ) {
        self.homeDirectory = homeDirectory
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.now = now
        self.commandRunner = commandRunner
        self.installationProbe = AgentBinaryInstallationProbe(
            homeDirectory: homeDirectory,
            environment: environment,
            commandRunner: commandRunner
        )
    }

    public func detectAll(forceRefresh: Bool = false) async -> [AgentStatus] {
        let currentDate = now()
        if !forceRefresh, let cachedStatuses, let cacheTimestamp,
           currentDate.timeIntervalSince(cacheTimestamp) < 60 {
            return cachedStatuses
        }

        var statuses: [AgentStatus] = []
        for agent in CLIAgent.allCases {
            statuses.append(detectStatus(agent))
        }
        statuses.sort { $0.agent.rawValue < $1.agent.rawValue }
        cachedStatuses = statuses
        cacheTimestamp = currentDate
        return statuses
    }

    public func detect(_ agent: CLIAgent) async -> AgentStatus {
        detectStatus(agent)
    }

    public func markConfigured(_ agent: CLIAgent) async {
        defaults.set(true, forKey: configuredKey(agent))
        defaults.set(now(), forKey: lastConfiguredKey(agent))
        invalidateCache()
    }

    public func clearConfigured(_ agent: CLIAgent) async {
        defaults.removeObject(forKey: configuredKey(agent))
        defaults.removeObject(forKey: lastConfiguredKey(agent))
        invalidateCache()
    }

    public func invalidateCache() {
        cachedStatuses = nil
        cacheTimestamp = nil
    }

    private func detectStatus(_ agent: CLIAgent) -> AgentStatus {
        let binaryPath = installationProbe.path(for: agent)
        let configured = binaryPath == nil ? false : isConfigured(agent)
        return AgentStatus(
            agent: agent,
            installed: binaryPath != nil,
            configured: configured,
            binaryPath: binaryPath,
            version: binaryPath.flatMap { commandRunner($0, ["--version"])?.line },
            lastConfigured: configured ? defaults.object(forKey: lastConfiguredKey(agent)) as? Date : nil
        )
    }

    private func isConfigured(_ agent: CLIAgent) -> Bool {
        if agent.configType == .environment {
            return defaults.bool(forKey: configuredKey(agent))
        }
        for path in agent.configPaths {
            let expandedPath = expand(path)
            guard !isSymbolicLink(expandedPath),
                  let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) else { continue }
            if content.contains("127.0.0.1") || content.contains("localhost") || content.contains("cliproxyapi") {
                return true
            }
        }
        return false
    }

    private func expand(_ path: String) -> String {
        path.hasPrefix("~") ? homeDirectory + path.dropFirst() : path
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func configuredKey(_ agent: CLIAgent) -> String { "agent.\(agent.rawValue).configured" }
    private func lastConfiguredKey(_ agent: CLIAgent) -> String { "agent.\(agent.rawValue).lastConfigured" }

    public nonisolated static func runCommand(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = arguments == ["--version"] ? pipe : FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }
}

private extension String {
    var line: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.components(separatedBy: .newlines).first
    }
}
