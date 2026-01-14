//
//  DaemonManager.swift
//  Quotio
//

import Foundation

@MainActor @Observable
final class DaemonManager {
    static let shared = DaemonManager()
    
    private(set) var isRunning = false
    private(set) var daemonPID: Int32?
    private(set) var lastError: String?
    
    private var process: Process?
    private var healthCheckTask: Task<Void, Never>?
    private let ipcClient = DaemonIPCClient.shared
    
    private init() {}
    
    var daemonBinaryPath: URL {
        // TODO: Add quotio-cli binary to app bundle via Copy Files build phase
        // For now, check in bundle first, then fall back to development path
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("quotio-cli"),
           FileManager.default.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }
        // Development fallback: check quotio-cli/dist in project root
        let projectRoot = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return projectRoot.appendingPathComponent("quotio-cli/dist/quotio")
    }
    
    var socketPath: String {
        // Must match quotio-cli daemon socket path: ~/.config/quotio/quotio.sock
        // Using XDG-compliant path for consistency with cross-platform CLI
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/quotio/quotio.sock"
    }
    
    func start() async throws {
        if isRunning { return }
        
        guard FileManager.default.fileExists(atPath: daemonBinaryPath.path) else {
            throw DaemonError.binaryNotFound
        }
        
        try await ensureSocketDirectoryExists()
        
        if FileManager.default.fileExists(atPath: socketPath) {
            if await checkHealth() {
                isRunning = true
                startHealthMonitoring()
                return
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        let proc = Process()
        proc.executableURL = daemonBinaryPath
        proc.arguments = ["daemon", "start", "--foreground"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        
        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(exitCode: process.terminationStatus)
            }
        }
        
        do {
            try proc.run()
            process = proc
            daemonPID = proc.processIdentifier
            
            try await waitForSocket(timeout: 5.0)
            isRunning = true
            lastError = nil
            startHealthMonitoring()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func stop() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        
        if await checkHealth() {
            do {
                try await ipcClient.shutdown(graceful: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch {}
        }
        
        if let proc = process, proc.isRunning {
            proc.terminate()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if proc.isRunning {
                proc.interrupt()
            }
        }
        
        process = nil
        daemonPID = nil
        isRunning = false
    }
    
    func restart() async throws {
        await stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await start()
    }
    
    func checkHealth() async -> Bool {
        do {
            let result = try await ipcClient.ping()
            return result.pong
        } catch {
            return false
        }
    }
    
    private func ensureSocketDirectoryExists() async throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
    
    private func waitForSocket(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if await checkHealth() {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        throw DaemonError.startupTimeout
    }
    
    private func startHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                
                if Task.isCancelled { break }
                
                let healthy = await checkHealth()
                if !healthy && isRunning {
                    isRunning = false
                    lastError = "Daemon connection lost"
                }
            }
        }
    }
    
    private func handleTermination(exitCode: Int32) {
        isRunning = false
        daemonPID = nil
        process = nil
        
        if exitCode != 0 {
            lastError = "Daemon exited with code \(exitCode)"
        }
    }
}

enum DaemonError: LocalizedError {
    case binaryNotFound
    case startupTimeout
    case connectionFailed
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Daemon binary not found in app bundle"
        case .startupTimeout:
            return "Daemon failed to start within timeout"
        case .connectionFailed:
            return "Failed to connect to daemon"
        }
    }
}
