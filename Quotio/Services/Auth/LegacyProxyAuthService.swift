import AppKit
import Foundation
import QuotioPresentation

nonisolated enum AuthCommand: Equatable, Sendable {
    case copilotLogin
    case kiroGoogleLogin
    case kiroAWSLogin
    case kiroAWSAuthCode
    case kiroImport

    var arguments: [String] {
        switch self {
        case .copilotLogin: ["-github-copilot-login"]
        case .kiroGoogleLogin: ["-kiro-google-login"]
        case .kiroAWSLogin: ["-kiro-aws-login"]
        case .kiroAWSAuthCode: ["-kiro-aws-authcode"]
        case .kiroImport: ["-kiro-import"]
        }
    }

    var displayName: String {
        switch self {
        case .copilotLogin: "GitHub Device Code"
        case .kiroGoogleLogin: "Google OAuth"
        case .kiroAWSLogin: "AWS Builder ID (Device Code)"
        case .kiroAWSAuthCode: "AWS Builder ID (Browser)"
        case .kiroImport: "Import from Kiro IDE"
        }
    }
}

nonisolated struct AuthCommandResult: Sendable {
    let success: Bool
    let message: String
    let deviceCode: String?
}

@MainActor
final class LegacyProxyAuthService {
    private let proxy: ProxyScreenModel
    private var process: Process?

    init(proxy: ProxyScreenModel) {
        self.proxy = proxy
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    func run(_ command: AuthCommand) async -> AuthCommandResult {
        terminate()
        guard proxy.isBinaryInstalled else {
            return AuthCommandResult(
                success: false,
                message: "CLIProxyAPI binary not found",
                deviceCode: nil
            )
        }

        return await withCheckedContinuation { continuation in
            let newProcess = Process()
            newProcess.executableURL = URL(fileURLWithPath: proxy.effectiveBinaryPath)
            newProcess.arguments = ["-config", proxy.configPath] + command.arguments
            let outputPipe = Pipe()
            newProcess.standardOutput = outputPipe
            newProcess.standardError = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            newProcess.environment = environment

            let state = AuthCommandState()
            @Sendable func finish(_ result: AuthCommandResult) {
                guard state.beginCompletion() else { return }
                continuation.resume(returning: result)
            }

            if command == .copilotLogin {
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                        state.append(output)
                    }
                }
            }
            newProcess.terminationHandler = { [weak self] terminatedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    self?.process = nil
                }
                if terminatedProcess.terminationStatus == 0 {
                    finish(AuthCommandResult(
                        success: true,
                        message: "Authentication completed successfully.",
                        deviceCode: nil
                    ))
                }
            }

            do {
                try newProcess.run()
                process = newProcess
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                    guard newProcess.isRunning else { return }
                    if command == .copilotLogin {
                        let code = Self.extractDeviceCode(from: state.output)
                        if let code {
                            DispatchQueue.main.async {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                            finish(AuthCommandResult(
                                success: true,
                                message: "🌐 Browser opened for GitHub authentication.\n\n📋 Code copied to clipboard:\n\n\(code)\n\nJust paste it in the browser!",
                                deviceCode: code
                            ))
                        } else {
                            finish(AuthCommandResult(
                                success: true,
                                message: "🌐 Browser opened for GitHub authentication.\n\nCheck your browser for the device code.",
                                deviceCode: nil
                            ))
                        }
                    } else {
                        finish(AuthCommandResult(
                            success: true,
                            message: "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.",
                            deviceCode: nil
                        ))
                    }
                }
            } catch {
                finish(AuthCommandResult(
                    success: false,
                    message: "Failed to start auth process: \(error.localizedDescription)",
                    deviceCode: nil
                ))
            }
        }
    }

    private nonisolated static func extractDeviceCode(from output: String) -> String? {
        if let start = output.range(of: "enter the code: "),
           let end = output[start.upperBound...].range(of: "\n") {
            return String(output[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        for line in output.components(separatedBy: "\n") where line.contains("enter the code:") {
            let parts = line.components(separatedBy: "enter the code:")
            if parts.count > 1 {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

private nonisolated final class AuthCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedOutput = ""
    private var hasCompleted = false

    var output: String {
        lock.withLock { capturedOutput }
    }

    func append(_ output: String) {
        lock.withLock { capturedOutput += output }
    }

    func beginCompletion() -> Bool {
        lock.withLock {
            guard !hasCompleted else { return false }
            hasCompleted = true
            return true
        }
    }
}

actor LegacyAntigravityAuthWorkaroundService {
    private let fileManager = FileManager.default

    func apply(in authDirectory: String) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDirectory) else { return }
        for file in files where file.hasSuffix(".json") && file.hasPrefix("antigravity-") {
            let path = (authDirectory as NSString).appendingPathComponent(file)
            let backupPath = path + ".bak"
            if !fileManager.fileExists(atPath: backupPath) {
                try? fileManager.copyItem(atPath: path, toPath: backupPath)
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            var metadata = json["metadata"] as? [String: Any] ?? [:]
            metadata["base_url"] = "https://daily-cloudcode-pa.googleapis.com"
            json["metadata"] = metadata
            if let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func remove(in authDirectory: String) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDirectory) else { return }
        var restoredCount = 0
        for file in files where file.hasSuffix(".json.bak") {
            let backupPath = (authDirectory as NSString).appendingPathComponent(file)
            let originalPath = String(backupPath.dropLast(4))
            do {
                if fileManager.fileExists(atPath: originalPath) {
                    try fileManager.removeItem(atPath: originalPath)
                }
                try fileManager.moveItem(atPath: backupPath, toPath: originalPath)
                restoredCount += 1
            } catch {
                continue
            }
        }
        guard restoredCount == 0 else { return }
        for file in files where file.hasSuffix(".json") && file.hasPrefix("antigravity-") {
            let path = (authDirectory as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var metadata = json["metadata"] as? [String: Any] else {
                continue
            }
            metadata.removeValue(forKey: "base_url")
            json["metadata"] = metadata
            if let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
