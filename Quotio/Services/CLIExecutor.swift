//
//  CLIExecutor.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Utility for executing CLI commands and parsing output
//  Used for quota-only mode to run commands like `claude /usage`, `codex /status`, etc.
//

import Foundation

/// Result of a CLI command execution
nonisolated struct CLIExecutionResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
    let success: Bool
    
    var combinedOutput: String {
        if errorOutput.isEmpty {
            return output
        }
        return output + "\n" + errorOutput
    }
}

/// Utility actor for executing CLI commands
actor CLIExecutor {
    static let shared = CLIExecutor()
    
    private init() {}
    
    /// Common CLI binary paths to search
    /// NOTE: Only checks file existence (metadata), does NOT read file content
    private let searchPaths = [
        // System paths
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        // User local
        "~/.local/bin",
        // Package managers
        "~/.cargo/bin",          // Rust/Cargo
        "~/.bun/bin",            // Bun (gemini-cli)
        "~/.deno/bin",           // Deno
        "~/.npm-global/bin",     // npm global
        // Tool-specific
        "~/.opencode/bin",       // OpenCode
        // Version managers (static shim paths)
        "~/.volta/bin",          // Volta
        "~/.asdf/shims",         // asdf
        "~/.local/share/mise/shims", // mise
    ]
    
    // MARK: - Binary Detection
    
    /// Check if a CLI binary exists and return its path
    func findBinary(named name: String) -> String? {
        // First check if it's in PATH
        let whichResult = executeSync(command: "/usr/bin/which", arguments: [name])
        if whichResult.success, !whichResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return whichResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Search common static paths
        for searchPath in searchPaths {
            let expandedPath = NSString(string: searchPath).expandingTildeInPath
            let binaryPath = (expandedPath as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: binaryPath) {
                return binaryPath
            }
        }
        
        // Search version manager paths (nvm, fnm)
        if let path = findInVersionManagerPaths(named: name) {
            return path
        }
        
        return nil
    }
    
    /// Find binary in version managers with versioned subdirectories
    private func findInVersionManagerPaths(named name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fileManager = FileManager.default
        
        // nvm: ~/.nvm/versions/node/v*/bin/
        let nvmBase = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmBase) {
            for version in versions.sorted().reversed() {
                let binPath = "\(nvmBase)/\(version)/bin/\(name)"
                if fileManager.isExecutableFile(atPath: binPath) {
                    return binPath
                }
            }
        }
        
        // fnm: ~/.fnm/node-versions/v*/installation/bin/
        let fnmBase = "\(home)/.fnm/node-versions"
        if let versions = try? fileManager.contentsOfDirectory(atPath: fnmBase) {
            for version in versions.sorted().reversed() {
                let binPath = "\(fnmBase)/\(version)/installation/bin/\(name)"
                if fileManager.isExecutableFile(atPath: binPath) {
                    return binPath
                }
            }
        }
        
        return nil
    }
    
    /// Check if a CLI is installed
    func isCLIInstalled(name: String) -> Bool {
        return findBinary(named: name) != nil
    }
    
    // MARK: - Command Execution
    
    /// Execute a command synchronously with timeout
    func executeSync(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) -> CLIExecutionResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }
        
        if let workDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }
        
        do {
            try process.run()
            
            // Wait with timeout
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            if process.isRunning {
                process.terminate()
                return CLIExecutionResult(
                    output: "",
                    errorOutput: "Command timed out after \(Int(timeout)) seconds",
                    exitCode: -1,
                    success: false
                )
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            return CLIExecutionResult(
                output: output,
                errorOutput: errorOutput,
                exitCode: process.terminationStatus,
                success: process.terminationStatus == 0
            )
        } catch {
            return CLIExecutionResult(
                output: "",
                errorOutput: error.localizedDescription,
                exitCode: -1,
                success: false
            )
        }
    }
    
    /// Execute a command asynchronously
    func execute(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) async -> CLIExecutionResult {
        return await withCheckedContinuation { continuation in
            Task.detached {
                let result = await self.executeSync(
                    command: command,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    timeout: timeout
                )
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Execute a CLI by name (auto-finds binary path)
    func executeCLI(
        name: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async -> CLIExecutionResult {
        guard let binaryPath = findBinary(named: name) else {
            return CLIExecutionResult(
                output: "",
                errorOutput: "CLI '\(name)' not found",
                exitCode: -1,
                success: false
            )
        }
        
        return await execute(
            command: binaryPath,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }
    
    // MARK: - PTY Execution (for interactive commands)
    
    /// Execute command in a pseudo-terminal (PTY) - needed for some CLIs
    func executePTY(
        command: String,
        arguments: [String] = [],
        input: String? = nil,
        timeout: TimeInterval = 30
    ) async -> CLIExecutionResult {
        // Use script command to create a PTY
        // This is needed for CLIs that behave differently without a TTY
        let scriptArgs = ["-q", "/dev/null", command] + arguments
        
        return await execute(
            command: "/usr/bin/script",
            arguments: scriptArgs,
            timeout: timeout
        )
    }
    
    /// Execute a CLI command that expects interactive input
    func executeCLIWithInput(
        name: String,
        arguments: [String] = [],
        input: String,
        timeout: TimeInterval = 30
    ) async -> CLIExecutionResult {
        guard let binaryPath = findBinary(named: name) else {
            return CLIExecutionResult(
                output: "",
                errorOutput: "CLI '\(name)' not found",
                exitCode: -1,
                success: false
            )
        }
        
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        
        do {
            try process.run()
            
            // Write input
            if let inputData = input.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(inputData)
                inputPipe.fileHandleForWriting.closeFile()
            }
            
            // Wait with timeout
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if process.isRunning {
                process.terminate()
                return CLIExecutionResult(
                    output: "",
                    errorOutput: "Command timed out",
                    exitCode: -1,
                    success: false
                )
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            return CLIExecutionResult(
                output: String(data: outputData, encoding: .utf8) ?? "",
                errorOutput: String(data: errorData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus,
                success: process.terminationStatus == 0
            )
        } catch {
            return CLIExecutionResult(
                output: "",
                errorOutput: error.localizedDescription,
                exitCode: -1,
                success: false
            )
        }
    }
}

// MARK: - Detected CLI Info

nonisolated struct DetectedCLI: Identifiable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let binaryPath: String?
    let isInstalled: Bool
    let version: String?
    
    static let allKnownCLIs: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "cursor": "Cursor",
        "gemini": "Gemini CLI",
        "gh": "GitHub CLI",
        "copilot": "GitHub Copilot"
    ]
}

// MARK: - CLI Detection Service

actor CLIDetectionService {
    static let shared = CLIDetectionService()
    
    private let executor = CLIExecutor.shared
    
    private init() {}
    
    /// Detect all installed CLIs
    func detectInstalledCLIs() async -> [DetectedCLI] {
        var detectedCLIs: [DetectedCLI] = []
        
        for (cliName, displayName) in DetectedCLI.allKnownCLIs {
            let binaryPath = await executor.findBinary(named: cliName)
            let isInstalled = binaryPath != nil
            
            var version: String? = nil
            if isInstalled, let path = binaryPath {
                let versionResult = await executor.execute(command: path, arguments: ["--version"], timeout: 5)
                if versionResult.success {
                    version = versionResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n").first
                }
            }
            
            detectedCLIs.append(DetectedCLI(
                id: cliName,
                name: cliName,
                displayName: displayName,
                binaryPath: binaryPath,
                isInstalled: isInstalled,
                version: version
            ))
        }
        
        return detectedCLIs.sorted { $0.displayName < $1.displayName }
    }
    
    /// Check if Claude CLI is installed
    func isClaudeInstalled() async -> Bool {
        return await executor.isCLIInstalled(name: "claude")
    }
    
    /// Check if Codex CLI is installed
    func isCodexInstalled() async -> Bool {
        return await executor.isCLIInstalled(name: "codex")
    }
    
    /// Check if Gemini CLI is installed
    func isGeminiInstalled() async -> Bool {
        return await executor.isCLIInstalled(name: "gemini")
    }
    
    /// Check if Cursor is installed (check for app or CLI)
    func isCursorInstalled() async -> Bool {
        // Check for Cursor.app
        let appPaths = [
            "/Applications/Cursor.app",
            "~/Applications/Cursor.app"
        ]
        
        for path in appPaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                return true
            }
        }
        
        return false
    }
}
