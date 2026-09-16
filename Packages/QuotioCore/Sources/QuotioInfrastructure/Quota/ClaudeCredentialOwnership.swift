import Foundation

/// Who owns a Claude credential, and therefore whether Quotio may renew it.
///
/// Quotio is a usage monitor and must not interfere with the CLI it observes.
/// Reading is not the boundary — refreshing is, because a refresh spends a token
/// the Claude Code CLI also holds. The CLI serializes refresh behind a
/// cross-process lock and marks a refresh token it did not spend itself as dead
/// on `invalid_grant`, so renewing on its behalf can sign the user out.
public enum ClaudeCredentialOwnership: Equatable, Sendable {
  /// Owned by the Claude Code CLI (`~/.claude/.credentials.json`, the
  /// `Claude Code-credentials` keychain item) or by Claude Desktop. Read-only:
  /// never refreshed, never written back.
  case externalCLI

  /// Owned by Quotio or its bundled proxy (`~/.cli-proxy-api/claude-*.json`,
  /// credentials in Quotio's own vault). Safe to refresh — the refresh lineage
  /// is independent of the CLI's.
  case quotio

  public var allowsRefresh: Bool {
    self == .quotio
  }

  /// The directory the Claude Code CLI stores its credentials in, honouring
  /// `CLAUDE_CONFIG_DIR` exactly as the CLI itself does.
  public static func configDirectory(
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
  /// Symlinks are never refreshed. A `claude-*.json` entry under
  /// `~/.cli-proxy-api` pointing at `~/.claude/.credentials.json` would
  /// otherwise classify as ours and spend the CLI's refresh token through the
  /// link. AGENTS.md requires that auth files never be followed through a
  /// symlink destination, so a link is treated as CLI-owned regardless of where
  /// it points — failing closed, since the only cost is not refreshing a file we
  /// did not create.
  public static func forAuthFile(
    at path: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> ClaudeCredentialOwnership {
    if containsSymbolicLink(at: path, fileManager: fileManager) { return .externalCLI }

    let expanded = (path as NSString).expandingTildeInPath
    let attributes = try? fileManager.attributesOfItem(atPath: expanded)
    let referenceCount = (attributes?[.referenceCount] as? NSNumber)?.uint64Value ?? 1
    return forOpenedAuthFile(
      at: expanded, referenceCount: referenceCount, environment: environment)
  }

  /// Classifies a file already opened without following symlinks.
  static func forOpenedAuthFile(
    at path: String,
    referenceCount: UInt64,
    environment: [String: String]
  ) -> ClaudeCredentialOwnership {
    // Multiple names can share the CLI's single-use refresh token even without
    // symlinks. Leave all multiply linked credentials read-only.
    if referenceCount > 1 { return .externalCLI }

    let file = canonicalPath(path)
    let cliDirectory = canonicalPath(configDirectory(environment: environment))
    return file == cliDirectory || file.hasPrefix(cliDirectory + "/") ? .externalCLI : .quotio
  }

  static func canonicalPath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
    for alias in ["/etc", "/tmp", "/var"]
    where standardized == alias || standardized.hasPrefix(alias + "/") {
      return "/private" + standardized
    }
    return standardized
  }

  static func containsSymbolicLink(
    at path: String, fileManager: FileManager = .default
  ) -> Bool {
    let url = URL(fileURLWithPath: path)
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      let attributes = try? fileManager.attributesOfItem(atPath: current.path)
      if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { return true }
    }
    return false
  }
}
