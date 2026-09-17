import Foundation
import QuotioInfrastructure
import XCTest

@MainActor
final class QuotioCLIServerProcessTests: XCTestCase {
    func testStartsFromAuthenticatedBootstrapAndStopsOnParentEOF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("stopped")
        let arguments = directory.appendingPathComponent("arguments")
        let environment = directory.appendingPathComponent("environment")
        let proxyAuthDirectory = directory.appendingPathComponent("proxy-auth")
        try FileManager.default.createDirectory(at: proxyAuthDirectory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("quotio-cli")
        let script = """
        #!/bin/sh
        trap 'printf stopped > "\(marker.path)"' EXIT
        printf '%s\n' "$@" > "\(arguments.path)"
        printf '%s\n%s\n' "$PATH" "$HTTPS_PROXY" > "\(environment.path)"
        IFS= read -r token
        [ -n "$token" ] || exit 2
        printf '{"bootstrap_version":1,"api_version":1,"pid":%s,"host":"127.0.0.1","port":43210}\n' "$$"
        cat >/dev/null
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let server = QuotioCLIServerProcess(
            executableURL: helper,
            configurationURL: directory.appendingPathComponent("config.toml"),
            accountDataDirectory: directory.appendingPathComponent("accounts"),
            proxyAuthDirectory: proxyAuthDirectory,
            executableDirectories: [directory.appendingPathComponent("bin")],
            proxyURL: { "http://proxy.example:8080" }
        )

        let connection = try await server.start()

        XCTAssertEqual(connection.baseURL.absoluteString, "http://127.0.0.1:43210")
        XCTAssertFalse(connection.token.isEmpty)
        let launchedArguments = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertTrue(launchedArguments.contains("--refresh-interval\n0\n"))
        XCTAssertTrue(launchedArguments.contains("--cli-proxy-auth-dir\n\(proxyAuthDirectory.path)\n"))
        let launchedEnvironment = try String(contentsOf: environment, encoding: .utf8)
        XCTAssertTrue(launchedEnvironment.hasPrefix("\(directory.path)/bin:"))
        XCTAssertTrue(launchedEnvironment.contains("\nhttp://proxy.example:8080\n"))
        await server.stop()
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRejectsBootstrapForAnotherProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("quotio-cli")
        let script = """
        #!/bin/sh
        IFS= read -r token
        printf '{"bootstrap_version":1,"api_version":1,"pid":1,"host":"127.0.0.1","port":43210}\n'
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let server = QuotioCLIServerProcess(
            executableURL: helper,
            configurationURL: directory.appendingPathComponent("config.toml"),
            accountDataDirectory: directory.appendingPathComponent("accounts")
        )

        do {
            _ = try await server.start()
            XCTFail("Expected incompatible bootstrap")
        } catch {
            XCTAssertEqual(error as? QuotioCLIServerError, .incompatibleBootstrap)
        }
    }
}
