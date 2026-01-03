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
    private static let terminationTimeout: TimeInterval = 5.0
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
    
    /// Kill all Antigravity helper processes that may hold database locks
    private func killHelperProcesses() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "Antigravity Helper"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try? process.run()
        process.waitUntilExit()
        
        // Small delay to ensure processes are fully terminated
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }
    
    /// Wait for all instances to terminate
    private func waitForTermination(timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
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
