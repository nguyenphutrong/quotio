import Foundation
import QuotioInfrastructure
import QuotioDomain
import QuotioApplication
import XCTest

@MainActor
final class QuotioCLIServerProcessTests: XCTestCase {
    func testHelperDiagnosticsKeepOnlyKnownEventsAndBoundedOSStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("quotio-cli")
        let script = """
        #!/bin/sh
        IFS= read -r token
        printf '%s\\n' 'Bearer do-not-log' >&2
        printf '%s\\n' '{"diagnostic_version":1,"event":"vault_keychain_read_failed","os_status":-25308,"token":"do-not-log"}' >&2
        printf '%s\\n' '{"diagnostic_version":1,"event":"do-not-log","os_status":-1}' >&2
        printf '%s\\n' '{"diagnostic_version":2,"event":"vault_keychain_read_failed","os_status":-1}' >&2
        printf '%s\\n' '{"diagnostic_version":1,"event":"vault_keychain_write_failed","os_status":2147483648}' >&2
        printf '%s' '\(String(repeating: "x", count: 1_100))' >&2
        printf '%s\\n' '{"diagnostic_version":1,"event":"vault_keychain_read_failed","os_status":-1}' >&2
        printf '%s' '{"diagnostic_version":1,"event":"vault_keychain_write_failed",' >&2
        printf '%s\\n' '"os_status":-25293}' >&2
        printf '%s\\n' '{"diagnostic_version":1,"event":"vault_keychain_authorize_failed","os_status":-128}' >&2
        printf '{"bootstrap_version":2,"api_version":2,"pid":%s,"host":"127.0.0.1","port":43210}\\n' "$$"
        cat >/dev/null
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let logger = HelperDiagnosticLogger()
        let server = QuotioCLIServerProcess(
            executableURL: helper,
            storage: .isolated(.init(namespace: "quotio-macos-test", applicationSupportDirectoryName: "app.bytrong.quotio")),
            configurationURL: directory.appendingPathComponent("config.toml"),
            accountDataDirectory: directory.appendingPathComponent("accounts"),
            logger: logger
        )
        _ = try await server.start()
        for _ in 0..<100 {
            if await logger.messages.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await server.stop()
        let messages = await logger.messages
        XCTAssertEqual(messages.count, 3)
        guard messages.count == 3 else { return }
        XCTAssertTrue(messages[0].contains("vault_keychain_read_failed os_status=-25308"))
        XCTAssertTrue(messages[1].contains("vault_keychain_write_failed os_status=-25293"))
        XCTAssertTrue(messages[2].contains("vault_keychain_authorize_failed os_status=-128"))
        XCTAssertFalse(messages.joined().contains("do-not-log"))
    }

    func testStartsFromAuthenticatedBootstrapAndStopsOnParentEOF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("stopped")
        let arguments = directory.appendingPathComponent("arguments")
        let handshake = directory.appendingPathComponent("handshake")
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
        printf '%s' "$token" > "\(handshake.path)"
        printf '{"bootstrap_version":2,"api_version":2,"pid":%s,"host":"127.0.0.1","port":43210}\n' "$$"
        cat >/dev/null
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let server = QuotioCLIServerProcess(
            executableURL: helper,
            storage: .isolated(.init(namespace: "quotio-macos-test", applicationSupportDirectoryName: "app.bytrong.quotio")),
            configurationURL: directory.appendingPathComponent("config.toml"),
            accountDataDirectory: directory.appendingPathComponent("accounts"),
            proxyAuthDirectory: proxyAuthDirectory,
            proxyConfigurationURL: directory.appendingPathComponent("proxy.yaml"),
            initialPreferences: { (ProviderTrackingPreferences(disabledProviders: [.copilot], automaticallyDiscoverLogins: false), RefreshPreferences(cadence: .manual), ["disabled.json"]) },
            proxyURL: { "http://proxy.example:8080" }
        )

        let connection = try await server.start()

        XCTAssertEqual(connection.baseURL.absoluteString, "http://127.0.0.1:43210")
        XCTAssertFalse(connection.token.isEmpty)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: handshake)) as? [String: Any])
        XCTAssertEqual(payload["token"] as? String, connection.token)
        let preferences = try XCTUnwrap(payload["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["disabled_providers"] as? [String], ["copilot"])
        XCTAssertEqual(preferences["automatically_discover_logins"] as? Bool, false)
        XCTAssertEqual(preferences["refresh_interval"] as? Int, 0)
        XCTAssertEqual(preferences["disabled_proxy_auth_files"] as? [String], ["disabled.json"])
        let launchedArguments = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertFalse(launchedArguments.contains("--refresh-interval"))
        XCTAssertFalse(launchedArguments.contains("--provider"))
        XCTAssertTrue(launchedArguments.contains("--account-vault-namespace\nquotio-macos-test\n"))
        XCTAssertTrue(launchedArguments.contains("--cli-proxy-auth-dir\n\(proxyAuthDirectory.path)\n"))
        XCTAssertTrue(launchedArguments.contains("--cli-proxy-config\n\(directory.appendingPathComponent("proxy.yaml").path)\n"))
        let launchedEnvironment = try String(contentsOf: environment, encoding: .utf8)
        XCTAssertTrue(launchedEnvironment.hasPrefix((ProcessInfo.processInfo.environment["PATH"] ?? "") + "\n"))
        XCTAssertTrue(launchedEnvironment.contains("\nhttp://proxy.example:8080\n"))
        await server.stop()
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStartupExitDoesNotNotifyRestartHandler() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("quotio-cli")
        try Data("#!/bin/sh\nread token\nexit 1\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let server = QuotioCLIServerProcess(
            executableURL: helper,
            storage: .isolated(.init(namespace: "quotio-macos-test", applicationSupportDirectoryName: "app.bytrong.quotio")),
            configurationURL: directory.appendingPathComponent("config.toml"),
            accountDataDirectory: directory.appendingPathComponent("accounts")
        )
        var terminations = 0
        server.onUnexpectedTermination = { terminations += 1 }
        for _ in 0..<3 {
            do {
                _ = try await server.start()
                XCTFail("Expected startup failure")
            } catch {
                XCTAssertEqual(error as? QuotioCLIServerError, .startupFailed)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(terminations, 0)
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
        printf '{"bootstrap_version":2,"api_version":2,"pid":1,"host":"127.0.0.1","port":43210}\n'
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let server = QuotioCLIServerProcess(
            executableURL: helper,
            storage: .isolated(.init(namespace: "quotio-macos-test", applicationSupportDirectoryName: "app.bytrong.quotio")),
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

private actor HelperDiagnosticLogger: ApplicationLogging {
    private(set) var messages: [String] = []

    func write(_ level: ApplicationLogLevel, message: String) {
        messages.append(message)
    }
}
