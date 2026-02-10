//
//  AntigravityDatabaseService.swift
//  Quotio
//
//  Handles reading/writing to Antigravity IDE's SQLite database
//  for token injection and active account detection.
//

import Foundation
import SQLite3

/// Service for interacting with Antigravity IDE's state database
actor AntigravityDatabaseService {
    
    // MARK: - Constants
    
    private static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
    
    private static let backupPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb.quotio.backup")
    
    private static let walPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb-wal")
    
    private static let shmPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb-shm")
    
    private static let oldFormatKey = "jetskiStateSync.agentManagerInitState"
    private static let newFormatKey = "antigravityUnifiedStateSync.oauthToken"
    private static let serviceMachineIdKey = "storage.serviceMachineId"
    
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
    
    // MARK: - SQLite Helpers
    
    private static let sqliteTimeout: TimeInterval = 10.0
    private static let sqliteBusyTimeoutMs: Int32 = Int32(sqliteTimeout * 1000)
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    
    private func withDatabase<T>(readOnly: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let openResult = sqlite3_open_v2(Self.databasePath.path, &db, flags, nil)
        
        if openResult == SQLITE_BUSY || openResult == SQLITE_LOCKED {
            throw DatabaseError.timeout
        }
        guard openResult == SQLITE_OK, let db else {
            let errorMessage = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if db != nil {
                sqlite3_close(db)
            }
            throw DatabaseError.writeFailed(
                NSError(domain: "SQLite", code: Int(openResult), userInfo: [NSLocalizedDescriptionKey: errorMessage])
            )
        }
        
        sqlite3_busy_timeout(db, Self.sqliteBusyTimeoutMs)
        defer { sqlite3_close(db) }
        
        return try body(db)
    }
    
    private func sqliteError(_ db: OpaquePointer?, code: Int32) -> NSError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
        return NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
    
    private func handleSQLiteResult(_ result: Int32, db: OpaquePointer?) throws {
        if result == SQLITE_BUSY || result == SQLITE_LOCKED {
            throw DatabaseError.timeout
        }
        guard result == SQLITE_OK else {
            throw DatabaseError.writeFailed(sqliteError(db, code: result))
        }
    }
    
    private func executeSimpleStatement(_ sql: String, db: OpaquePointer) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        try handleSQLiteResult(result, db: db)
    }
    
    private func readValue(forKey key: String, db: OpaquePointer) throws -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = ?;"
        var statement: OpaquePointer?
        
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        try handleSQLiteResult(prepareResult, db: db)
        defer { sqlite3_finalize(statement) }
        
        let bindResult = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, Self.sqliteTransient) }
        guard bindResult == SQLITE_OK else {
            throw DatabaseError.writeFailed(sqliteError(db, code: bindResult))
        }
        
        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            guard let valuePtr = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return String(cString: valuePtr)
        case SQLITE_DONE:
            return nil
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw DatabaseError.timeout
        default:
            throw DatabaseError.writeFailed(sqliteError(db, code: stepResult))
        }
    }
    
    private func writeValue(_ value: String, forKey key: String, db: OpaquePointer) throws {
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?);"
        var statement: OpaquePointer?
        
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        try handleSQLiteResult(prepareResult, db: db)
        defer { sqlite3_finalize(statement) }
        
        let bindKeyResult = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, Self.sqliteTransient) }
        guard bindKeyResult == SQLITE_OK else {
            throw DatabaseError.writeFailed(sqliteError(db, code: bindKeyResult))
        }
        
        let bindValueResult = value.withCString { sqlite3_bind_text(statement, 2, $0, -1, Self.sqliteTransient) }
        guard bindValueResult == SQLITE_OK else {
            throw DatabaseError.writeFailed(sqliteError(db, code: bindValueResult))
        }
        
        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_DONE:
            return
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw DatabaseError.timeout
        default:
            throw DatabaseError.writeFailed(sqliteError(db, code: stepResult))
        }
    }
    
    /// Read current state value from database (returns base64 string)
    func readStateValue() async throws -> String {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }

        let result = try withDatabase(readOnly: true) { db in
            try readValue(forKey: Self.oldFormatKey, db: db)
        }
        
        guard let value = result, !value.isEmpty else {
            throw DatabaseError.stateNotFound
        }
        
        return value
    }
    
    /// Write new state value to database (base64 string)
    func writeStateValue(_ value: String) async throws {
        guard databaseExists() else {
            throw DatabaseError.databaseNotFound
        }
        try withDatabase(readOnly: false) { db in
            try writeValue(value, forKey: Self.oldFormatKey, db: db)
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
    
    /// Remove WAL and SHM files to release database locks
    /// Should be called after IDE termination
    func cleanupWALFiles() async {
        try? FileManager.default.removeItem(at: Self.walPath)
        try? FileManager.default.removeItem(at: Self.shmPath)
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

        let result = try withDatabase(readOnly: true) { db in
            try readValue(forKey: Self.authStatusKey, db: db)
        }
        
        guard let value = result, !value.isEmpty, let jsonData = value.data(using: .utf8) else {
            return nil
        }
        
        let authStatus = try? JSONDecoder().decode(AuthStatus.self, from: jsonData)
        return authStatus?.email
    }
    
    // MARK: - Token Operations
    
    // ════════════════════════════════════════════════════════════════════════
    // Constants for retry policy
    // ════════════════════════════════════════════════════════════════════════
    
    private static let defaultMaxRetries = 3
    private static let baseRetryDelayNs: UInt64 = 1_000_000_000  // 1 second
    
    /// Inject token into database with automatic retry on database lock.
    /// - Parameters:
    ///   - accessToken: OAuth access token
    ///   - refreshToken: OAuth refresh token
    ///   - expiry: Token expiry timestamp (Unix seconds)
    ///   - maxRetries: Maximum retry attempts (default: 3)
    /// - Throws: Last encountered error after all retries exhausted
    func injectToken(
        accessToken: String,
        refreshToken: String,
        expiry: Int64,
        email: String,
        versionFormat: AntigravityVersionDetector.VersionFormat = .unknown,
        maxRetries: Int = defaultMaxRetries
    ) async throws {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                try injectTokenOnce(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiry: expiry,
                    email: email,
                    versionFormat: versionFormat
                )
                return
            } catch {
                lastError = error
                
                guard case DatabaseError.timeout = error, attempt < maxRetries else {
                    if attempt >= maxRetries { break }
                    throw error
                }
                
                let delayNs = Self.baseRetryDelayNs * UInt64(attempt)
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
        
        throw lastError ?? DatabaseError.timeout
    }
    
    private func injectTokenOnce(
        accessToken: String,
        refreshToken: String,
        expiry: Int64,
        email: String,
        versionFormat: AntigravityVersionDetector.VersionFormat
    ) throws {
        try withDatabase(readOnly: false) { db in
            try executeSimpleStatement("BEGIN IMMEDIATE TRANSACTION;", db: db)
            var shouldRollback = true
            defer {
                if shouldRollback {
                    try? executeSimpleStatement("ROLLBACK;", db: db)
                }
            }
            
            switch versionFormat {
            case .newFormat:
                try injectNewFormat(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiry: expiry,
                    db: db
                )
                
            case .oldFormat:
                try injectOldFormat(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiry: expiry,
                    email: email,
                    db: db
                )
                
            case .unknown:
                // Dual fallback: try both formats
                let newFormatResult = Result {
                    try injectNewFormat(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiry: expiry,
                        db: db
                    )
                }
                let oldFormatResult = Result {
                    try injectOldFormat(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiry: expiry,
                        email: email,
                        db: db
                    )
                }
                
                if case .failure = newFormatResult, case .failure(let oldErr) = oldFormatResult {
                    throw oldErr
                }
            }
            
            try writeValue("true", forKey: "antigravityOnboarding", db: db)
            try executeSimpleStatement("COMMIT;", db: db)
            shouldRollback = false
        }
    }
    
    // MARK: - Format-Specific Injection
    
    /// New format (>= 1.16.5): write to antigravityUnifiedStateSync.oauthToken
    private func injectNewFormat(
        accessToken: String,
        refreshToken: String,
        expiry: Int64,
        db: OpaquePointer
    ) throws {
        let payload = AntigravityProtobufHandler.createNewFormatPayload(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry
        )
        try writeValue(payload, forKey: Self.newFormatKey, db: db)
    }
    
    /// Old format (< 1.16.5): modify existing jetskiStateSync.agentManagerInitState
    private func injectOldFormat(
        accessToken: String,
        refreshToken: String,
        expiry: Int64,
        email: String,
        db: OpaquePointer
    ) throws {
        guard let currentState = try readValue(forKey: Self.oldFormatKey, db: db),
              !currentState.isEmpty else {
            // Old key doesn't exist — likely new-version Antigravity, skip silently
            Log.debug("Old format key not found, skipping old format injection")
            return
        }
        
        let newState = try AntigravityProtobufHandler.injectTokenOldFormat(
            existingBase64: currentState,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry,
            email: email
        )
        
        try writeValue(newState, forKey: Self.oldFormatKey, db: db)
    }
    
    // MARK: - ServiceMachineId Sync
    
    /// Sync storage.serviceMachineId into state.vscdb ItemTable
    func syncServiceMachineId(_ machineId: String) async throws {
        guard databaseExists() else { return }
        try withDatabase(readOnly: false) { db in
            try writeValue(machineId, forKey: Self.serviceMachineIdKey, db: db)
        }
    }
    
    /// Get current token info from database (for detecting active account)
    func getCurrentTokenInfo() async throws -> (accessToken: String?, refreshToken: String?, expiry: Int64?) {
        let currentState = try await readStateValue()
        return try AntigravityProtobufHandler.extractOAuthInfo(base64Data: currentState)
    }
}
