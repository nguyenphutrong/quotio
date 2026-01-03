//
//  AntigravityDatabaseService.swift
//  Quotio
//
//  Handles reading/writing to Antigravity IDE's SQLite database
//  for token injection and active account detection.
//

import Foundation

/// Service for interacting with Antigravity IDE's state database
actor AntigravityDatabaseService {
    
    // MARK: - Constants
    
    private static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
    
    private static let backupPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb.quotio.backup")
    
    private static let stateKey = "jetskiStateSync.agentManagerInitState"
    
    // MARK: - Errors
    
    enum DatabaseError: LocalizedError {
        case databaseNotFound
        case stateNotFound
        case backupFailed(Error)
        case restoreFailed(Error)
        case writeFailed(Error)
        case invalidData
        case timeout
        
        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                return "Antigravity IDE database not found. Please ensure Antigravity is installed."
            case .stateNotFound:
                return "State data not found in database. Please log in to Antigravity IDE first."
            case .backupFailed(let error):
                return "Failed to create backup: \(error.localizedDescription)"
            case .restoreFailed(let error):
                return "Failed to restore backup: \(error.localizedDescription)"
            case .writeFailed(let error):
                return "Failed to write to database: \(error.localizedDescription)"
            case .invalidData:
                return "Invalid data format in database"
            case .timeout:
                return "Database operation timed out. The database may be locked by another process."
            }
        }
    }
    
    // MARK: - Database Operations
    
    /// Check if Antigravity database exists
    func databaseExists() -> Bool {
        FileManager.default.fileExists(atPath: Self.databasePath.path)
    }
    
    // MARK: - SQLite CLI Helpers
    
    private static let sqliteTimeout: TimeInterval = 10.0
    
    /// Execute sqlite3 command and return output asynchronously with timeout
    private func executeSQLite(_ sql: String, readOnly: Bool = true) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        
        // Use -readonly flag for read operations
        if readOnly {
            process.arguments = ["-readonly", Self.databasePath.path, sql]
        } else {
            process.arguments = [Self.databasePath.path, sql]
        }
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        
        // Wait with timeout to prevent indefinite blocking
        let waitResult = await waitForProcessWithTimeout(process, timeout: Self.sqliteTimeout)
        
        if !waitResult {
            // Process timed out - terminate it
            process.terminate()
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms grace period
            if process.isRunning {
                process.interrupt() // Force kill if still running
            }
            throw DatabaseError.timeout
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
        
        let terminationStatus = process.terminationStatus
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if terminationStatus != 0 {
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw DatabaseError.writeFailed(NSError(domain: "SQLite", code: Int(terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorMessage]))
        }
        
        return output
    }
    
    /// Wait for process to exit with timeout
    private func waitForProcessWithTimeout(_ process: Process, timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        
        while process.isRunning {
            if Date().timeIntervalSince(startTime) >= timeout {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms polling
        }
        
        return true
    }
    
    /// Read current state value from database (returns base64 string)
    func readStateValue() async throws -> String {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }
        
        // Escape single quotes in key
        let escapedKey = Self.stateKey.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT value FROM ItemTable WHERE key = '\(escapedKey)';"
        
        let result = try await executeSQLite(sql)
        
        guard !result.isEmpty else {
            throw DatabaseError.stateNotFound
        }
        
        return result
    }
    
    /// Write new state value to database (base64 string)
    func writeStateValue(_ value: String) async throws {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }
        
        // Escape single quotes
        let escapedKey = Self.stateKey.replacingOccurrences(of: "'", with: "''")
        let escapedValue = value.replacingOccurrences(of: "'", with: "''")
        
        // Use INSERT OR REPLACE to handle both insert and update
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(escapedKey)', '\(escapedValue)');"
        
        _ = try await executeSQLite(sql, readOnly: false)
    }
    
    // MARK: - Backup/Restore
    
    /// Create backup of database before modification
    func createBackup() async throws {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }
        
        do {
            // Remove existing backup if present
            if FileManager.default.fileExists(atPath: Self.backupPath.path) {
                try FileManager.default.removeItem(at: Self.backupPath)
            }
            
            try FileManager.default.copyItem(at: Self.databasePath, to: Self.backupPath)
        } catch {
            throw DatabaseError.backupFailed(error)
        }
    }
    
    /// Restore database from backup
    func restoreFromBackup() async throws {
        guard FileManager.default.fileExists(atPath: Self.backupPath.path) else {
            throw DatabaseError.restoreFailed(NSError(domain: "Quotio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No backup found"]))
        }
        
        do {
            // Remove current database
            if FileManager.default.fileExists(atPath: Self.databasePath.path) {
                try FileManager.default.removeItem(at: Self.databasePath)
            }
            
            // Restore from backup
            try FileManager.default.copyItem(at: Self.backupPath, to: Self.databasePath)
        } catch {
            throw DatabaseError.restoreFailed(error)
        }
    }
    
    /// Remove backup file after successful operation
    func removeBackup() async {
        try? FileManager.default.removeItem(at: Self.backupPath)
    }
    
    /// Check if backup exists
    func backupExists() -> Bool {
        FileManager.default.fileExists(atPath: Self.backupPath.path)
    }
    
    // MARK: - Auth Status Operations
    
    private static let authStatusKey = "antigravityAuthStatus"
    
    /// Auth status structure from antigravityAuthStatus key
    private struct AuthStatus: Codable {
        let email: String?
        let name: String?
        let apiKey: String?  // This is actually the access_token
    }
    
    /// Get the email of currently active account in IDE
    /// Reads from antigravityAuthStatus which contains {email, name, apiKey}
    func getActiveEmail() async throws -> String? {
        guard databaseExists() else {
            return nil
        }
        
        let escapedKey = Self.authStatusKey.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT value FROM ItemTable WHERE key = '\(escapedKey)';"
        
        let result = try await executeSQLite(sql)
        
        guard !result.isEmpty, let jsonData = result.data(using: .utf8) else {
            return nil
        }
        
        let authStatus = try? JSONDecoder().decode(AuthStatus.self, from: jsonData)
        return authStatus?.email
    }
    
    // MARK: - Token Operations
    
    /// Inject token into database
    /// - Parameters:
    ///   - accessToken: OAuth access token
    ///   - refreshToken: OAuth refresh token
    ///   - expiry: Token expiry timestamp (Unix seconds)
    func injectToken(accessToken: String, refreshToken: String, expiry: Int64) async throws {
        // Read current state
        let currentState = try await readStateValue()
        
        // Inject new token
        let newState = try AntigravityProtobufHandler.injectToken(
            existingBase64: currentState,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry
        )
        
        // Write back to database
        try await writeStateValue(newState)
    }
    
    /// Get current token info from database (for detecting active account)
    func getCurrentTokenInfo() async throws -> (accessToken: String?, refreshToken: String?, expiry: Int64?) {
        let currentState = try await readStateValue()
        return try AntigravityProtobufHandler.extractOAuthInfo(base64Data: currentState)
    }
}
