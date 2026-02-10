//
//  AntigravityProcessManager.swift
//  Quotio
//
//  Manages Antigravity IDE process lifecycle for account switching.
//  Handles detection, graceful termination, and restart.
//

import Foundation
import AppKit

/// Manages Antigravity IDE process lifecycle
@MainActor
final class AntigravityProcessManager {
    
    // MARK: - Constants
    
    /// Bundle identifiers for Antigravity IDE (multiple possible values)
    private static let bundleIdentifiers = [
        "com.google.antigravity",           // Official Google release
        "com.todesktop.230313mzl4w4u92"     // ToDesktop wrapped version
    ]
    private static let appName = "Antigravity"
    private static let terminationTimeout: TimeInterval = 20.0
    private static let forceKillTimeout: TimeInterval = 3.0
    
    // MARK: - Singleton
    
    static let shared = AntigravityProcessManager()
    private init() {}
    
    // MARK: - Process Detection
    
    /// Check if Antigravity IDE is currently running
    func isRunning() -> Bool {
        !runningInstances().isEmpty
    }
    
    /// Get running Antigravity application instances
    private func runningInstances() -> [NSRunningApplication] {
        var instances: [NSRunningApplication] = []
        for bundleId in Self.bundleIdentifiers {
            instances.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleId))
        }
        return instances
    }
    
    // MARK: - Process Control
    
    /// Gracefully terminate Antigravity IDE
    /// - Returns: true if successfully terminated, false if force kill was needed
    @discardableResult
    func terminate() async -> Bool {
        let apps = runningInstances()
        guard !apps.isEmpty else { return true }
        
        // Send SIGTERM (graceful termination)
        for app in apps {
            app.terminate()
        }
        
        // Wait for graceful termination
        let gracefullyTerminated = await waitForTermination(timeout: Self.terminationTimeout)
        
        if gracefullyTerminated {
            // Also kill any remaining helper processes
            await killHelperProcesses()
            return true
        }
        
        // Force kill if still running
        for app in apps {
            app.forceTerminate()
        }
        
        // Wait for force termination
        _ = await waitForTermination(timeout: Self.forceKillTimeout)
        
        // Kill any orphaned helper processes that may still hold database locks
        await killHelperProcesses()
        
        return false
    }
    
    /// Terminate Antigravity and any helper processes, even if the main app is not running
    @discardableResult
    func terminateAllProcesses() async -> Bool {
        let terminated = await terminate()
        await killHelperProcesses()
        return terminated
    }
    
    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Process Cleanup
    // ════════════════════════════════════════════════════════════════════════
    
    /// Kill all Antigravity helper processes that may hold database locks.
    /// Executes blocking operations on a detached task to avoid blocking MainActor.
    /// Compatible with macOS 14+, 15+, 26+.
    private func killHelperProcesses() async {
        let helperPatterns = [
            "Antigravity Helper",
            "Antigravity Helper (GPU)",
            "Antigravity Helper (Plugin)",
            "Antigravity Helper (Renderer)"
        ]

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                // Method 1: Use killall for each helper pattern (most reliable)
                for pattern in helperPatterns {
                    let killall = Process()
                    killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                    killall.arguments = ["-9", pattern, "-t", "2"]  // -t 2s timeout
                    killall.standardOutput = FileHandle.nullDevice
                    killall.standardError = FileHandle.nullDevice
                    try? killall.run()
                    killall.waitUntilExit()
                }

                // Method 2: Use pkill as fallback (catches any remaining)
                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkill.arguments = ["-9", "-f", "Antigravity Helper"]
                pkill.standardOutput = FileHandle.nullDevice
                pkill.standardError = FileHandle.nullDevice
                try? pkill.run()
                pkill.waitUntilExit()

                continuation.resume()
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }
    
    /// Wait for all instances to terminate
    /// - Parameter timeout: Maximum time to wait
    /// - Returns: true if terminated, false if timeout or cancelled
    private func waitForTermination(timeout: TimeInterval) async -> Bool {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if Task.isCancelled {
                return false
            }
            if runningInstances().isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return runningInstances().isEmpty
    }
    
    /// Launch Antigravity IDE
    func launch() async throws {
        // Try to find Antigravity in Applications folder first
        let applicationsPath = "/Applications/Antigravity.app"
        let userApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity.app")
        
        var appURL: URL?
        
        if FileManager.default.fileExists(atPath: applicationsPath) {
            appURL = URL(fileURLWithPath: applicationsPath)
        } else if FileManager.default.fileExists(atPath: userApplicationsPath.path) {
            appURL = userApplicationsPath
        } else {
            // Try to find using bundle identifiers
            for bundleId in Self.bundleIdentifiers {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    appURL = url
                    break
                }
            }
        }
        
        guard let url = appURL else {
            throw ProcessError.applicationNotFound
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        
        let workspace = NSWorkspace.shared
        try await workspace.openApplication(at: url, configuration: configuration)
    }
    
    // MARK: - Errors
    
    enum ProcessError: LocalizedError {
        case applicationNotFound
        case terminationFailed
        case launchFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .applicationNotFound:
                return "Antigravity IDE not found. Please ensure it is installed."
            case .terminationFailed:
                return "Failed to terminate Antigravity IDE"
            case .launchFailed(let error):
                return "Failed to launch Antigravity IDE: \(error.localizedDescription)"
            }
        }
    }
}
