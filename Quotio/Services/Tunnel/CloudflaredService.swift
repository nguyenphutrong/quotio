//
//  CloudflaredService.swift
//  Quotio - Cloudflared subprocess management
//

import Foundation

actor CloudflaredService {
    
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    private static let binaryPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared"
    ]
    
    private static let tunnelURLPattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#
    
    nonisolated func detectInstallation() -> CloudflaredInstallation {
        for path in Self.binaryPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                let version = getVersion(at: path)
                return CloudflaredInstallation(isInstalled: true, path: path, version: version)
            }
        }
        return .notInstalled
    }
    
    private nonisolated func getVersion(at path: String) -> String? {
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
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            if let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                return String(output[match])
            }
            return nil
        } catch {
            return nil
        }
    }
    
    func start(port: UInt16, onURLDetected: @escaping @Sendable (String) -> Void) async throws {
        guard process == nil else {
            throw TunnelError.alreadyRunning
        }
        
        let installation = detectInstallation()
        guard installation.isInstalled, let binaryPath = installation.path else {
            throw TunnelError.notInstalled
        }
        
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: binaryPath)
        // Use --config /dev/null to ignore user's existing config file
        // This ensures Quick Tunnel works without interference from named tunnels
        newProcess.arguments = ["tunnel", "--config", "/dev/null", "--url", "http://localhost:" + String(port)]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        newProcess.standardOutput = outputPipe
        newProcess.standardError = errorPipe
        
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer = ""
            private var urlFound = false
            private let maxBufferSize = 65536 // 64KB max buffer
            
            func append(_ text: String) -> String? {
                lock.lock()
                defer { lock.unlock() }
                
                guard !urlFound else { return nil }
                buffer += text
                
                // Trim buffer to keep only trailing maxBufferSize characters
                if buffer.count > maxBufferSize {
                    let dropCount = buffer.count - maxBufferSize
                    buffer = String(buffer.dropFirst(dropCount))
                }
                
                if let range = buffer.range(of: CloudflaredService.tunnelURLPattern, options: .regularExpression) {
                    urlFound = true
                    return String(buffer[range])
                }
                return nil
            }
            
            func checkRemaining() -> String? {
                lock.lock()
                defer { lock.unlock() }
                
                guard !urlFound else { return nil }
                
                if let range = buffer.range(of: CloudflaredService.tunnelURLPattern, options: .regularExpression) {
                    urlFound = true
                    return String(buffer[range])
                }
                return nil
            }
        }
        
        let buffer = OutputBuffer()
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            
            // EOF detected - empty data means stream closed
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Check remaining buffer for URL on EOF
                if let url = buffer.checkRemaining() {
                    onURLDetected(url)
                }
                return
            }
            
            guard let text = String(data: data, encoding: .utf8) else { return }
            
            if let url = buffer.append(text) {
                onURLDetected(url)
            }
        }
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            
            // EOF detected - empty data means stream closed
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Check remaining buffer for URL on EOF
                if let url = buffer.checkRemaining() {
                    onURLDetected(url)
                }
                return
            }
            
            guard let text = String(data: data, encoding: .utf8) else { return }
            
            if let url = buffer.append(text) {
                onURLDetected(url)
            }
        }
        
        do {
            try newProcess.run()
            self.process = newProcess
            NSLog("[CloudflaredService] Started tunnel on port %d, PID: %d", port, newProcess.processIdentifier)
        } catch {
            cleanup()
            throw TunnelError.startFailed(error.localizedDescription)
        }
    }
    
    func stop() async {
        guard let process = process, process.isRunning else {
            cleanup()
            return
        }
        
        let pid = process.processIdentifier
        NSLog("[CloudflaredService] Stopping tunnel, PID: %d", pid)
        
        process.terminate()
        
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        
        if process.isRunning {
            NSLog("[CloudflaredService] Force killing tunnel, PID: %d", pid)
            kill(pid, SIGKILL)
        }
        
        cleanup()
    }
    
    var isRunning: Bool {
        process?.isRunning ?? false
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
    
    nonisolated static func killOrphanProcesses() {
        // Use app-specific pattern matching tunnels spawned by Quotio (--config /dev/null)
        let pattern = "cloudflared.*tunnel.*--config.*/dev/null.*--url"
        
        // First try graceful SIGTERM
        let termProcess = Process()
        termProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        termProcess.arguments = ["-TERM", "-f", pattern]
        termProcess.standardOutput = FileHandle.nullDevice
        termProcess.standardError = FileHandle.nullDevice
        
        do {
            try termProcess.run()
            termProcess.waitUntilExit()
            
            // Wait briefly for graceful shutdown
            Thread.sleep(forTimeInterval: 0.3)
            
            // Check if any matching processes remain and force kill
            let killProcess = Process()
            killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killProcess.arguments = ["-9", "-f", pattern]
            killProcess.standardOutput = FileHandle.nullDevice
            killProcess.standardError = FileHandle.nullDevice
            
            try killProcess.run()
            killProcess.waitUntilExit()
            
            NSLog("[CloudflaredService] Cleaned up orphan cloudflared processes")
        } catch {
            // Silent failure - no orphans to kill is fine
        }
    }
}

enum TunnelError: Error, Sendable {
    case notInstalled
    case alreadyRunning
    case startFailed(String)
    case unexpectedExit
    
    var localizedMessage: String {
        switch self {
        case .notInstalled:
            return "Cloudflared is not installed"
        case .alreadyRunning:
            return "Tunnel is already running"
        case .startFailed(let reason):
            return "Failed to start tunnel: \(reason)"
        case .unexpectedExit:
            return "Tunnel exited unexpectedly"
        }
    }
}
