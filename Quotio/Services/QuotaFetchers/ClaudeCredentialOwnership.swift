import Foundation

/// Who owns a Claude credential, and therefore whether Quotio may renew it.
///
/// Quotio is a usage monitor and must not interfere with the CLI it observes.
/// Reading is not the boundary — refreshing is, because a refresh spends a token
/// the Claude Code CLI also holds. The CLI serializes refresh behind a
/// cross-process lock and marks a refresh token it did not spend itself as dead
/// on `invalid_grant`, so renewing on its behalf can sign the user out.
nonisolated enum ClaudeCredentialOwnership: Equatable {
    /// Owned by the Claude Code CLI (`~/.claude/.credentials.json`, the
    /// `Claude Code-credentials` keychain item). Read-only: never refreshed,
    /// never written back.
    case claudeCodeCLI

    /// Owned by Quotio or its bundled proxy (`~/.cli-proxy-api/claude-*.json`,
    /// credentials in Quotio's own vault). Safe to refresh — the refresh lineage
    /// is independent of the CLI's.
    case quotio

    var allowsRefresh: Bool {
        self == .quotio
    }

    /// The directory the Claude Code CLI stores its credentials in, honouring
    /// `CLAUDE_CONFIG_DIR` exactly as the CLI itself does.
    static func claudeCLIConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let configured = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return NSString(string: "~/.claude").expandingTildeInPath
    }

    /// Classify an auth file by the directory it lives in.
    ///
    /// Anything inside the CLI's config directory belongs to the CLI; auth files
    /// elsewhere (`~/.cli-proxy-api/`) are ours.
    ///
    /// Symlinks are never refreshed. `standardizingPath` does not resolve them,
    /// so a `claude-*.json` entry under `~/.cli-proxy-api` pointing at
    /// `~/.claude/.credentials.json` would otherwise classify as ours and spend
    /// the CLI's refresh token through the link. AGENTS.md requires that auth
    /// files never be followed through a symlink destination, so a link is
    /// treated as CLI-owned regardless of where it points — failing closed,
    /// since the only cost is not refreshing a file we did not create.
    static func forAuthFile(
        at path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ClaudeCredentialOwnership {
        if isSymbolicLink(at: path, fileManager: fileManager) { return .claudeCodeCLI }

        let file = (path as NSString).resolvingSymlinksInPath
        let cliDirectory = (claudeCLIConfigDirectory(environment: environment) as NSString)
            .resolvingSymlinksInPath
        return file == cliDirectory || file.hasPrefix(cliDirectory + "/") ? .claudeCodeCLI : .quotio
    }

    private static func isSymbolicLink(at path: String, fileManager: FileManager) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}
