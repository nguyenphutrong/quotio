@preconcurrency import Foundation
import Darwin
import QuotioApplication
import QuotioDomain

public actor ProxyProcessController: ProxyProcessControlling {
    private final class ManagedProcess: @unchecked Sendable {
        let process: Process
        let outputPipe: Pipe
        let errorPipe: Pipe

        init(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
        }

        func closePipes() {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }
    }

    private var processes: [ProxyRunID: ManagedProcess] = [:]

    public init() {}

    public static func launchArguments(for request: ProxyProcessRequest) -> [String] {
        ["-config", request.configurationPath]
    }

    public static func processIDsToTerminate(from output: String, ownPID: Int32) -> [Int32] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard let processID = Int32(line.trimmingCharacters(in: .whitespaces)),
                  processID != ownPID else {
                return nil
            }
            return processID
        }
    }

    public func start(
        _ request: ProxyProcessRequest,
        termination: @escaping @Sendable (ProxyProcessExit) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = Self.launchArguments(for: request)
        process.currentDirectoryURL = URL(fileURLWithPath: request.executablePath)
            .deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData.count
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData.count
        }

        let managed = ManagedProcess(
            process: process,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )
        process.terminationHandler = { [weak self, managed] terminatedProcess in
            managed.closePipes()
            let exit = ProxyProcessExit(
                runID: request.runID,
                processID: terminatedProcess.processIdentifier,
                exitCode: terminatedProcess.terminationStatus
            )
            termination(exit)
            Task {
                await self?.removeProcess(
                    runID: request.runID,
                    processID: terminatedProcess.processIdentifier
                )
            }
        }

        do {
            try process.run()
            processes[request.runID] = managed
        } catch {
            managed.closePipes()
            throw error
        }
    }

    public func isRunning(_ runID: ProxyRunID) -> Bool {
        processes[runID]?.process.isRunning == true
    }

    public func stop(_ runID: ProxyRunID?, on port: UInt16) async {
        if let runID, let managed = processes.removeValue(forKey: runID) {
            await terminate(managed)
        }
        await Self.killProcesses(on: port)
    }

    public func cleanupProcesses(on port: UInt16) async {
        await Self.killProcesses(on: port)
        try? await Task.sleep(for: .milliseconds(200))
    }

    public func firstAvailablePort(
        in range: ClosedRange<UInt16>,
        excluding excludedPort: UInt16
    ) throws -> UInt16 {
        for port in range where port != excludedPort {
            if !Self.isPortInUse(port) {
                return port
            }
        }
        throw ProxyFailure.dryRunFailed("No available port for testing")
    }

    private func removeProcess(runID: ProxyRunID, processID: Int32) {
        guard processes[runID]?.process.processIdentifier == processID else { return }
        processes.removeValue(forKey: runID)
    }

    private func terminate(_ managed: ManagedProcess) async {
        let process = managed.process
        guard process.isRunning else {
            managed.closePipes()
            return
        }
        let processID = process.processIdentifier
        process.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(processID, SIGKILL)
        }
        managed.closePipes()
    }

    private nonisolated static func killProcesses(on port: UInt16) async {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-ti", "tcp:\(port)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                    return
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                for processID in processIDsToTerminate(from: output, ownPID: ownPID) {
                    kill(processID, SIGKILL)
                }
            } catch {
                return
            }
        }.value
    }

    private nonisolated static func isPortInUse(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) != 0
            }
        }
    }
}
