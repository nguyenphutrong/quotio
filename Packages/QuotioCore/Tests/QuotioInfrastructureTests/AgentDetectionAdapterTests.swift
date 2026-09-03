import Foundation
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class AgentDetectionAdapterTests: XCTestCase {
    func testAgentPathsAndBinaryNamesRemainStable() {
        XCTAssertEqual(CLIAgent.claudeCode.configPaths, ["~/.claude/settings.json"])
        XCTAssertEqual(CLIAgent.codexCLI.configPaths, ["~/.codex/config.toml", "~/.codex/auth.json"])
        XCTAssertEqual(CLIAgent.ampCLI.configPaths, ["~/.config/amp/settings.json", "~/.local/share/amp/secrets.json"])
        XCTAssertEqual(CLIAgent.openCode.binaryNames, ["opencode", "oc"])
        XCTAssertEqual(CLIAgent.factoryDroid.binaryNames, ["droid", "factory-droid"])
    }

    func testDetectsAllAgentsFromBinariesConfigsAndExactDefaultsMarkers() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "AgentDetectionAdapterTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let binaries = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        for name in ["claude", "codex", "amp", "opencode", "droid"] {
            let url = binaries.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for agent in CLIAgent.allCases {
            let path = home.appendingPathComponent(String(agent.configPaths[0].dropFirst()))
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "endpoint = 'http://127.0.0.1:8317'".write(to: path, atomically: true, encoding: .utf8)
        }
        let adapter = AgentDetectionAdapter(
            homeDirectory: home.path,
            environment: [:],
            defaultsSuiteName: suite,
            now: { date },
            commandRunner: { executable, arguments in
                executable == "/usr/bin/which" ? nil : "test-version\nmore"
            }
        )

        for agent in CLIAgent.allCases {
            await adapter.markConfigured(agent)
            let persisted = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertTrue(persisted.bool(forKey: "agent.\(agent.rawValue).configured"))
            XCTAssertEqual(persisted.object(forKey: "agent.\(agent.rawValue).lastConfigured") as? Date, date)
        }
        let statuses = await adapter.detectAll(forceRefresh: true)

        XCTAssertEqual(statuses.map(\.agent.rawValue), statuses.map(\.agent.rawValue).sorted())
        XCTAssertTrue(statuses.allSatisfy { $0.installed && $0.configured })
        XCTAssertTrue(statuses.allSatisfy { $0.version == "test-version" && $0.lastConfigured == date })

        for agent in CLIAgent.allCases {
            await adapter.clearConfigured(agent)
            let persisted = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertNil(persisted.object(forKey: "agent.\(agent.rawValue).configured"))
            XCTAssertNil(persisted.object(forKey: "agent.\(agent.rawValue).lastConfigured"))
        }
    }

    func testForceRefreshInvalidatesSixtySecondCache() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let adapter = AgentDetectionAdapter(homeDirectory: home.path, environment: [:], commandRunner: { _, _ in nil })

        let initial = await adapter.detectAll(forceRefresh: false)
        XCTAssertTrue(initial.first { $0.agent == .claudeCode }?.installed == true)
        try FileManager.default.removeItem(at: binary)
        let cached = await adapter.detectAll(forceRefresh: false)
        XCTAssertTrue(cached.first { $0.agent == .claudeCode }?.installed == true)
        let refreshed = await adapter.detectAll(forceRefresh: true)
        XCTAssertTrue(refreshed.first { $0.agent == .claudeCode }?.installed == false)
    }

    func testConfigurationDetectionDoesNotFollowSymbolicLinks() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent(".local/bin/claude")
        let config = home.appendingPathComponent(".claude/settings.json")
        let target = home.appendingPathComponent("outside.json")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try "http://127.0.0.1:8317".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        let adapter = AgentDetectionAdapter(
            homeDirectory: home.path,
            environment: [:],
            commandRunner: { _, _ in nil }
        )

        let status = await adapter.detect(.claudeCode)

        XCTAssertTrue(status.installed)
        XCTAssertFalse(status.configured)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
