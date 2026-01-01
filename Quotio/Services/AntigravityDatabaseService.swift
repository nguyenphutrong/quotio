//
//  AntigravityDatabaseService.swift
//  Quotio
//
//  Handles reading/writing to Antigravity IDE's SQLite database
//  for token injection and active account detection.
//

import Foundation
import SQLite

/// Service for interacting with Antigravity IDE's state database
actor AntigravityDatabaseService {
    
    // MARK: - Constants
    
    private static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
    
    private static let backupPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb.quotio.backup")
    
    private static let stateKey = "jetskiStateSync.agentManagerInitState"
    
    // SQLite table structure - value is stored as TEXT (base64 string), not BLOB
    private let itemTable = Table("ItemTable")
    private let keyColumn = SQLite.Expression<String>("key")
    private let valueColumn = SQLite.Expression<String?>("value")
    
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
    
    /// Read current state value from database (returns base64 string)
    func readStateValue() async throws -> String {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }
        
        let db = try Connection(Self.databasePath.path, readonly: true)
        
        let query = itemTable.filter(keyColumn == Self.stateKey)
        guard let row = try db.pluck(query) else {
            throw DatabaseError.stateNotFound
        }
        
        guard let stringValue = row[valueColumn], !stringValue.isEmpty else {
            throw DatabaseError.invalidData
        }
        
        return stringValue
    }
    
    /// Write new state value to database (base64 string)
    func writeStateValue(_ value: String) async throws {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }
        
        do {
            let db = try Connection(Self.databasePath.path)
            
            let query = itemTable.filter(keyColumn == Self.stateKey)
            let update = query.update(valueColumn <- value)
            
            let rowsUpdated = try db.run(update)
            
            if rowsUpdated == 0 {
                // Key doesn't exist, insert instead
                let insert = itemTable.insert(keyColumn <- Self.stateKey, valueColumn <- value)
                try db.run(insert)
            }
        } catch {
            throw DatabaseError.writeFailed(error)
        }
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
        
        let db = try Connection(Self.databasePath.path, readonly: true)
        
        let query = itemTable.filter(keyColumn == Self.authStatusKey)
        guard let row = try db.pluck(query),
              let jsonString = row[valueColumn],
              let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }
        
        let authStatus = try JSONDecoder().decode(AuthStatus.self, from: jsonData)
        return authStatus.email
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
