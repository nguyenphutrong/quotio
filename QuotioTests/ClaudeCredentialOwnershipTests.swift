import Foundation
import XCTest
@testable import Quotio

/// The boundary that keeps Quotio from interfering with the Claude Code CLI:
/// credentials the CLI owns are read, never refreshed or written back.
final class ClaudeCredentialOwnershipTests: XCTestCase {
    private let home = NSString(string: "~").expandingTildeInPath

    func testNativeCredentialsFileIsCLIOwnedAndNotRefreshable() {
        let path = "\(home)/.claude/.credentials.json"
        let ownership = ClaudeCredentialOwnership.forAuthFile(at: path, environment: [:])
        XCTAssertEqual(ownership, .claudeCodeCLI)
        XCTAssertFalse(ownership.allowsRefresh, "Refreshing spends the CLI's single-use refresh token")
    }

    func testProxyAuthFilesRemainRefreshable() {
        for name in ["claude-user.json", "claude-work@example.com.json"] {
            let path = "\(home)/.cli-proxy-api/\(name)"
            let ownership = ClaudeCredentialOwnership.forAuthFile(at: path, environment: [:])
            XCTAssertEqual(ownership, .quotio, "\(name) is owned by Quotio's proxy")
            XCTAssertTrue(ownership.allowsRefresh)
        }
    }

    func testClaudeConfigDirOverrideIsHonoured() {
        let custom = "\(home)/custom-claude-home"
        let environment = ["CLAUDE_CONFIG_DIR": custom]

        XCTAssertEqual(
            ClaudeCredentialOwnership.forAuthFile(at: "\(custom)/.credentials.json", environment: environment),
            .claudeCodeCLI,
            "A relocated CLI config directory is still CLI-owned"
        )
        XCTAssertEqual(
            ClaudeCredentialOwnership.forAuthFile(at: "\(home)/.claude/.credentials.json", environment: environment),
            .quotio,
            "With the override set, the default directory is no longer the CLI's"
        )
    }

    func testConfigDirOverrideExpandsTildeAndIgnoresBlankValues() {
        XCTAssertEqual(
            ClaudeCredentialOwnership.claudeCLIConfigDirectory(environment: ["CLAUDE_CONFIG_DIR": "~/relocated"]),
            "\(home)/relocated"
        )
        XCTAssertEqual(
            ClaudeCredentialOwnership.claudeCLIConfigDirectory(environment: ["CLAUDE_CONFIG_DIR": "   "]),
            "\(home)/.claude",
            "A blank override falls back to the default, matching the CLI"
        )
        XCTAssertEqual(
            ClaudeCredentialOwnership.claudeCLIConfigDirectory(environment: [:]),
            "\(home)/.claude"
        )
    }

    // MARK: - Symlinks

    /// A `claude-*.json` entry under `~/.cli-proxy-api` that links to the CLI's
    /// credentials would otherwise classify as ours, and the refresh would be
    /// spent through the link. AGENTS.md forbids following an auth-file symlink.
    func testSymlinkIntoCLIDirectoryIsNotRefreshable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cliDirectory = root.appendingPathComponent(".claude")
        let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
        try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = cliDirectory.appendingPathComponent(".credentials.json")
        try Data("{}".utf8).write(to: target)
        let link = proxyDirectory.appendingPathComponent("claude-linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let environment = ["CLAUDE_CONFIG_DIR": cliDirectory.path]
        let ownership = ClaudeCredentialOwnership.forAuthFile(at: link.path, environment: environment)
        XCTAssertEqual(ownership, .claudeCodeCLI)
        XCTAssertFalse(ownership.allowsRefresh, "Refreshing through the link spends the CLI's token")
    }

    /// Fail closed: any symlinked auth file is left unrefreshed, even one
    /// pointing somewhere harmless, because we do not follow the destination.
    func testSymlinkWithinProxyDirectoryIsAlsoNotRefreshed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
        try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = proxyDirectory.appendingPathComponent("claude-real.json")
        try Data("{}".utf8).write(to: target)
        let link = proxyDirectory.appendingPathComponent("claude-alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(ClaudeCredentialOwnership.forAuthFile(at: target.path, environment: [:]), .quotio)
        XCTAssertEqual(ClaudeCredentialOwnership.forAuthFile(at: link.path, environment: [:]), .claudeCodeCLI)
    }

    func testSiblingDirectoryIsNotMistakenForCLIDirectory() {
        XCTAssertEqual(
            ClaudeCredentialOwnership.forAuthFile(at: "\(home)/.claude-backup/.credentials.json", environment: [:]),
            .quotio,
            "Prefix matching must not treat ~/.claude-backup as part of ~/.claude"
        )
    }

    func testUnnormalizedPathsInsideCLIDirectoryAreCLIOwned() {
        XCTAssertEqual(
            ClaudeCredentialOwnership.forAuthFile(at: "\(home)/.claude/../.claude/.credentials.json", environment: [:]),
            .claudeCodeCLI,
            "Path traversal must not smuggle a CLI-owned file into the refreshable branch"
        )
    }
}
