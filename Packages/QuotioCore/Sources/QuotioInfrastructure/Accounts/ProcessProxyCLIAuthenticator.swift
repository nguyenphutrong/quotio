import Foundation
import QuotioApplication

public actor ProcessProxyCLIAuthenticator: ProxyCLIAuthenticating {
    public typealias DeviceCodeHandler = @MainActor @Sendable (String) -> Void

    private let copyDeviceCode: DeviceCodeHandler
    private var process: Process?

    public init(copyDeviceCode: @escaping DeviceCodeHandler) {
        self.copyDeviceCode = copyDeviceCode
    }

    public func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    public func run(
        _ command: ProxyCLIAuthCommand,
        runtime: ProxyCLIAuthRuntime
    ) async -> ProxyCLIAuthResult {
        terminate()
        let copyDeviceCode = copyDeviceCode
        return await withCheckedContinuation { continuation in
            let newProcess = Process()
            newProcess.executableURL = URL(fileURLWithPath: runtime.binaryPath)
            newProcess.arguments = ["-config", runtime.configurationPath] + command.arguments
            let outputPipe = Pipe()
            newProcess.standardOutput = outputPipe
            newProcess.standardError = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            newProcess.environment = environment

            let state = ProxyCLIAuthCommandState()
            @Sendable func finish(_ result: ProxyCLIAuthResult) {
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
                Task { await self?.clearProcess() }
                finish(ProxyCLIAuthResult(
                    success: terminatedProcess.terminationStatus == 0,
                    status: terminatedProcess.terminationStatus == 0
                        ? .authenticationCompleted
                        : .authenticationCancelled,
                    deviceCode: nil
                ))
            }

            do {
                try newProcess.run()
                process = newProcess
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard newProcess.isRunning else { return }
                    if command == .copilotLogin {
                        let code = Self.extractDeviceCode(from: state.output)
                        if let code { await copyDeviceCode(code) }
                        finish(ProxyCLIAuthResult(
                            success: true,
                            status: .copilotBrowserOpened(deviceCode: code),
                            deviceCode: code
                        ))
                    } else {
                        finish(ProxyCLIAuthResult(
                            success: true,
                            status: .browserOpened,
                            deviceCode: nil
                        ))
                    }
                }
            } catch {
                finish(ProxyCLIAuthResult(
                    success: false,
                    status: .failedToStart(details: error.localizedDescription),
                    deviceCode: nil
                ))
            }
        }
    }

    nonisolated static func extractDeviceCode(from output: String) -> String? {
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

    private func clearProcess() {
        process = nil
    }
}

private nonisolated final class ProxyCLIAuthCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedOutput = ""
    private var hasCompleted = false

    var output: String { lock.withLock { capturedOutput } }

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
