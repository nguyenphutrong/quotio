import Darwin
import Foundation
import QuotioApplication
import QuotioDomain

public actor CloudflaredService: TunnelControlling {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    private static let binaryPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared",
    ]

    private static let tunnelURLPattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#

    public init() {}

    public func detectInstallation() -> CloudflaredInstallation {
        for path in Self.binaryPaths where FileManager.default.isExecutableFile(atPath: path) {
            return CloudflaredInstallation(
                isInstalled: true,
                path: path,
                version: version(at: path)
            )
        }
        return .notInstalled
    }

    public func start(
        port: UInt16,
        onURLDetected: @escaping @Sendable (String) -> Void
    ) async throws {
        guard process == nil else {
            throw TunnelFailure.alreadyRunning
        }

        let installation = detectInstallation()
        guard installation.isInstalled, let binaryPath = installation.path else {
            throw TunnelFailure.notInstalled
        }

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: binaryPath)
        newProcess.arguments = [
            "tunnel",
            "--config", "/dev/null",
            "--protocol", "http2",
            "--url", "http://localhost:" + String(port),
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        newProcess.standardOutput = outputPipe
        newProcess.standardError = errorPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        let buffer = TunnelOutputBuffer(pattern: Self.tunnelURLPattern)
        let readabilityHandler: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let url = buffer.detectURL() {
                    onURLDetected(url)
                }
                return
            }
            guard let text = String(data: data, encoding: .utf8),
                  let url = buffer.append(text) else {
                return
            }
            onURLDetected(url)
        }
        outputPipe.fileHandleForReading.readabilityHandler = readabilityHandler
        errorPipe.fileHandleForReading.readabilityHandler = readabilityHandler

        do {
            try newProcess.run()
            process = newProcess
        } catch {
            cleanup()
            throw TunnelFailure.startFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        guard let process, process.isRunning else {
            cleanup()
            return
        }

        process.terminate()
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        cleanup()
    }

    public func isRunning() -> Bool {
        process?.isRunning ?? false
    }

    public func cleanupOrphans() {
        let pattern = "cloudflared.*tunnel.*--config.*/dev/null.*--url"
        runPKill(arguments: ["-TERM", "-f", pattern])
        Thread.sleep(forTimeInterval: 0.3)
        runPKill(arguments: ["-9", "-f", pattern])
    }

    private func version(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8),
                  let match = output.range(
                    of: #"\d+\.\d+\.\d+"#,
                    options: .regularExpression
                  ) else {
                return nil
            }
            return String(output[match])
        } catch {
            return nil
        }
    }

    private func runPKill(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // No matching process is an expected cleanup outcome.
        }
    }

    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        outputPipe = nil
        errorPipe = nil
        process = nil
    }
}

private final class TunnelOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let pattern: String
    private let maximumSize = 65_536
    private var buffer = ""
    private var didFindURL = false

    init(pattern: String) {
        self.pattern = pattern
    }

    func append(_ text: String) -> String? {
        lock.withLock {
            guard !didFindURL else { return nil }
            buffer += text
            if buffer.count > maximumSize {
                buffer = String(buffer.suffix(maximumSize))
            }
            return detectURLLocked()
        }
    }

    func detectURL() -> String? {
        lock.withLock { detectURLLocked() }
    }

    private func detectURLLocked() -> String? {
        guard !didFindURL,
              let range = buffer.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        didFindURL = true
        return String(buffer[range])
    }
}
