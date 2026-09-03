import Foundation
import QuotioApplication
import QuotioDomain

public actor ShellProfileAdapter: ShellProfileRepository {
    private let homeDirectory: String
    private let environment: [String: String]
    private let fileStore: AgentFileStore
    private let fileManager: FileManager

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileStore: AgentFileStore? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.fileStore = fileStore ?? AgentFileStore(homeDirectory: homeDirectory)
        self.fileManager = FileManager()
    }

    public func detect() async -> ShellProfile {
        let shell: ShellType
        switch environment["SHELL"] ?? "" {
        case let value where value.contains("bash"): shell = .bash
        case let value where value.contains("fish"): shell = .fish
        default: shell = .zsh
        }
        return ShellProfile(shell: shell, path: profilePath(for: shell))
    }

    public func add(configuration: String, for agent: CLIAgent, to profile: ShellProfile) async throws {
        let oldContent = try await fileStore.string(at: profile.path) ?? ""
        var content = removingBlock(for: agent, from: oldContent)
        let markers = markerPair(for: agent)
        content += "\n\(markers.start)\n\(configuration)\n\(markers.end)"
        _ = try await fileStore.apply([AgentFileWrite(path: profile.path, data: Data(content.utf8))])
    }

    public func removeConfiguration(for agent: CLIAgent, from profile: ShellProfile) async throws {
        guard let oldContent = try await fileStore.string(at: profile.path) else { return }
        let content = removingBlock(for: agent, from: oldContent)
        guard content != oldContent else { return }
        _ = try await fileStore.apply([AgentFileWrite(path: profile.path, data: Data(content.utf8))])
    }

    public func profilePath(for shell: ShellType) -> String {
        switch shell {
        case .zsh:
            if let zdotdir = environment["ZDOTDIR"], !zdotdir.isEmpty {
                return zdotdir + "/.zshrc"
            }
            let xdg = environment["XDG_CONFIG_HOME"] ?? homeDirectory + "/.config"
            let xdgZsh = xdg + "/zsh"
            return fileManager.fileExists(atPath: xdgZsh) ? xdgZsh + "/.zshrc" : homeDirectory + "/.zshrc"
        case .bash:
            return homeDirectory + "/.bashrc"
        case .fish:
            return homeDirectory + "/.config/fish/config.fish"
        }
    }

    private func removingBlock(for agent: CLIAgent, from original: String) -> String {
        let markers = markerPair(for: agent)
        guard let start = original.range(of: markers.start),
              let end = original.range(of: markers.end, range: start.upperBound..<original.endIndex) else {
            return original
        }
        var lower = start.lowerBound
        if lower > original.startIndex, original[original.index(before: lower)] == "\n" {
            lower = original.index(before: lower)
        }
        var upper = end.upperBound
        if upper < original.endIndex, original[upper] == "\n" {
            upper = original.index(after: upper)
        }
        var result = original
        result.removeSubrange(lower..<upper)
        return result
    }

    private func markerPair(for agent: CLIAgent) -> (start: String, end: String) {
        let name: String
        switch agent {
        case .claudeCode: name = "Claude Code"
        case .codexCLI: name = "Codex CLI"
        case .ampCLI: name = "Amp CLI"
        case .openCode: name = "OpenCode"
        case .factoryDroid: name = "Factory Droid"
        }
        return ("# CLIProxyAPI Configuration for \(name)", "# End CLIProxyAPI Configuration for \(name)")
    }
}
