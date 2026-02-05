//
//  Logger.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Unified logging service with privacy-aware output.
//  Only logs in DEBUG builds to prevent sensitive data leakage in production.
//

import Foundation
import os.log

/// Unified logger for Quotio with privacy controls.
/// All logging is disabled in Release builds to prevent sensitive data leakage.
/// Marked nonisolated to be callable from any actor context.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.quotio"
    
    // MARK: - Log Categories
    // os.Logger is thread-safe and can be called from any context
    
    private static let apiLogger = Logger(subsystem: subsystem, category: "API")
    private static let quotaLogger = Logger(subsystem: subsystem, category: "Quota")
    private static let proxyLogger = Logger(subsystem: subsystem, category: "Proxy")
    private static let authLogger = Logger(subsystem: subsystem, category: "Auth")
    private static let generalLogger = Logger(subsystem: subsystem, category: "General")
    private static let keychainLogger = Logger(subsystem: subsystem, category: "Keychain")
    private static let warmupLogger = Logger(subsystem: subsystem, category: "Warmup")
    private static let updateLogger = Logger(subsystem: subsystem, category: "Update")
    
    // MARK: - Public Logging Methods
    
    /// Log API-related debug messages
    static func api(_ message: String, file: String = #file, function: String = #function) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        apiLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log quota fetching debug messages
    static func quota(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        quotaLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log proxy-related debug messages
    static func proxy(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        proxyLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log authentication-related debug messages
    static func auth(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        authLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log keychain-related debug messages
    static func keychain(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        keychainLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log warmup-related debug messages
    static func warmup(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        warmupLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log update-related debug messages
    static func update(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        updateLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log general debug messages
    static func debug(_ message: String, file: String = #file) {
        #if DEBUG
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        generalLogger.debug("[\(filename)] \(message)")
        #endif
    }
    
    /// Log warning messages (also logged in Release for important warnings)
    static func warning(_ message: String, file: String = #file) {
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        generalLogger.warning("[\(filename)] ⚠️ \(message)")
    }
    
    /// Log error messages (always logged)
    static func error(_ message: String, file: String = #file) {
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        generalLogger.error("[\(filename)] ❌ \(message)")
    }
    
    // MARK: - Privacy Helpers
    
    /// Mask sensitive data for logging (e.g., account IDs, emails)
    static func mask(_ value: String, visibleChars: Int = 4) -> String {
        guard value.count > visibleChars else { return String(repeating: "*", count: value.count) }
        let prefix = String(value.prefix(visibleChars))
        return prefix + String(repeating: "*", count: max(0, value.count - visibleChars))
    }
    
    /// Mask email for logging (shows first part before @)
    static func maskEmail(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@") else { return mask(email) }
        let localPart = String(email[..<atIndex])
        let domain = String(email[atIndex...])
        return mask(localPart, visibleChars: 2) + domain
    }
}
