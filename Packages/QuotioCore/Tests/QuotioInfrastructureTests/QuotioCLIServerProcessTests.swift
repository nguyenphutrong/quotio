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
        let helper = directory.appendingPathComponent("quotio-cli")
        let script = """
        #!/bin/sh
        trap 'printf stopped > "\(marker.path)"' EXIT
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
            accountDataDirectory: directory.appendingPathComponent("accounts")
        )

        let connection = try await server.start()

        XCTAssertEqual(connection.baseURL.absoluteString, "http://127.0.0.1:43210")
        XCTAssertFalse(connection.token.isEmpty)
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
