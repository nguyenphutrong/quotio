import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class ShellProfileAdapterTests: XCTestCase {
    func testShellSelectionAndProfilePathRules() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let bash = await ShellProfileAdapter(homeDirectory: home.path, environment: ["SHELL": "/bin/bash"]).detect()
        XCTAssertEqual(bash, ShellProfile(shell: .bash, path: home.appendingPathComponent(".bashrc").path))

        let zdotdir = home.appendingPathComponent("zsh-home").path
        let zsh = await ShellProfileAdapter(
            homeDirectory: home.path,
            environment: ["SHELL": "/bin/zsh", "ZDOTDIR": zdotdir]
        ).detect()
        XCTAssertEqual(zsh.path, zdotdir + "/.zshrc")

        let xdg = home.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("zsh"), withIntermediateDirectories: true)
        let xdgZsh = await ShellProfileAdapter(
            homeDirectory: home.path,
            environment: ["XDG_CONFIG_HOME": xdg.path]
        ).detect()
        XCTAssertEqual(xdgZsh.path, xdg.appendingPathComponent("zsh/.zshrc").path)

        let fish = await ShellProfileAdapter(homeDirectory: home.path, environment: ["SHELL": "/opt/fish"]).detect()
        XCTAssertEqual(fish.path, home.appendingPathComponent(".config/fish/config.fish").path)
    }

    func testMarkerReplacementAndRemovalPreserveContentPermissionsAndBackups() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profileURL = home.appendingPathComponent(".zshrc")
        let original = "export KEEP=1\n\n# CLIProxyAPI Configuration for Claude Code\nexport OLD=1\n# End CLIProxyAPI Configuration for Claude Code\nalias kept='yes'\n"
        try original.write(to: profileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: profileURL.path)
        let store = AgentFileStore(homeDirectory: home.path, now: { Date(timeIntervalSince1970: 1234) })
        let adapter = ShellProfileAdapter(homeDirectory: home.path, environment: [:], fileStore: store)
        let profile = ShellProfile(shell: .zsh, path: profileURL.path)

        try await adapter.add(configuration: "export NEW=1", for: .claudeCode, to: profile)
        var content = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("export KEEP=1"))
        XCTAssertTrue(content.contains("alias kept='yes'"))
        XCTAssertFalse(content.contains("export OLD=1"))
        XCTAssertEqual(content.components(separatedBy: "# CLIProxyAPI Configuration for Claude Code").count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path + ".backup.1234"))
        XCTAssertEqual(try permissions(profileURL), 0o640)

        try await adapter.removeConfiguration(for: .claudeCode, from: profile)
        content = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertFalse(content.contains("CLIProxyAPI Configuration for Claude Code"))
        XCTAssertTrue(content.contains("export KEEP=1") && content.contains("alias kept='yes'"))
        XCTAssertEqual(try permissions(profileURL), 0o640)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path + ".backup.1235"))
    }

    func testUsesExactMarkersForEveryAgent() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = ShellProfile(shell: .zsh, path: home.appendingPathComponent(".zshrc").path)
        let adapter = ShellProfileAdapter(homeDirectory: home.path, environment: [:])
        let names: [CLIAgent: String] = [
            .claudeCode: "Claude Code", .codexCLI: "Codex CLI", .ampCLI: "Amp CLI",
            .openCode: "OpenCode", .factoryDroid: "Factory Droid",
        ]
        for agent in CLIAgent.allCases {
            try await adapter.add(configuration: "export TEST=1", for: agent, to: profile)
        }
        let content = try String(contentsOfFile: profile.path, encoding: .utf8)
        for name in names.values {
            XCTAssertTrue(content.contains("# CLIProxyAPI Configuration for \(name)"))
            XCTAssertTrue(content.contains("# End CLIProxyAPI Configuration for \(name)"))
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
