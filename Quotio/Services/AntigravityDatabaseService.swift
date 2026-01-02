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
            }
        }
    }
    
    // MARK: - Database Operations
    
    /// Check if Antigravity database exists
    func databaseExists() -> Bool {
        FileManager.default.fileExists(atPath: Self.databasePath.path)
    }
    
    // MARK: - SQLite CLI Helpers
    
    /// Execute sqlite3 command and return output asynchronously
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
        
        // Collect output data using readabilityHandler for non-blocking reads
        var outputData = Data()
        var errorData = Data()
        let outputLock = NSLock()
        let errorLock = NSLock()
        
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputLock.lock()
            outputData.append(data)
            outputLock.unlock()
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorLock.lock()
            errorData.append(data)
            errorLock.unlock()
        }
        
        try process.run()
        
        // Await process completion using continuation
        let terminationStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { terminatedProcess in
                // Remove handlers and close file handles to avoid resource leaks
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                
                // Read any remaining data
                outputLock.lock()
                outputData.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                outputLock.unlock()
                
                errorLock.lock()
                errorData.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                errorLock.unlock()
                
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
        }
        
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if terminationStatus != 0 {
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw DatabaseError.writeFailed(NSError(domain: "SQLite", code: Int(terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorMessage]))
        }
        
        return output
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
