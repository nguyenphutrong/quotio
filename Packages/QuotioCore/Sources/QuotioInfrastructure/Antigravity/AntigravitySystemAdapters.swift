import AppKit
import Foundation
import QuotioDomain
import SQLite3

enum AntigravityVersionDetection {
    private static let threshold = [1, 16, 5]
    private static let bundleIDs = ["com.google.antigravity", "com.todesktop.230313mzl4w4u92"]

    @MainActor static func detectFormat() -> AntigravityTokenFormat {
        guard let version = detectVersion() else { return .unknown }
        return isAtLeastThreshold(version.shortVersion) ? .unified : .legacy
    }

    @MainActor static func detectVersion() -> AntigravityInstalledVersion? {
        var urls = [
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Antigravity.app"),
        ]
        urls += bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        for url in urls {
            let info = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: info),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let short = plist["CFBundleShortVersionString"] as? String else { continue }
            return .init(shortVersion: short, bundleVersion: plist["CFBundleVersion"] as? String ?? short)
        }
        return nil
    }

    static func components(_ version: String) -> [Int] {
        var result = version.split(separator: ".").map { Int($0) ?? 0 }
        while result.count < threshold.count { result.append(0) }
        return result
    }

    static func isAtLeastThreshold(_ version: String) -> Bool {
        for (value, minimum) in zip(components(version), threshold) {
            if value != minimum { return value > minimum }
        }
        return true
    }
}

@MainActor
final class AntigravityIDEProcess {
    private static let bundleIDs = ["com.google.antigravity", "com.todesktop.230313mzl4w4u92"]

    func isRunning() -> Bool { !instances().isEmpty }

    func terminateAll() async -> Bool {
        let applications = instances()
        applications.forEach { $0.terminate() }
        if await waitUntilStopped(seconds: 20) {
            await killHelpers()
            return true
        }
        applications.forEach { $0.forceTerminate() }
        _ = await waitUntilStopped(seconds: 3)
        await killHelpers()
        return false
    }

    func launch() async throws {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Antigravity.app"),
        ]
        let url = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? Self.bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func instances() -> [NSRunningApplication] {
        Self.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    private func waitUntilStopped(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if instances().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return instances().isEmpty
    }

    private func killHelpers() async {
        await Task.detached(priority: .userInitiated) {
            for name in ["Antigravity Helper", "Antigravity Helper (GPU)",
                         "Antigravity Helper (Plugin)", "Antigravity Helper (Renderer)"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["-9", name, "-t", "2"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-9", "-f", "Antigravity Helper"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value
        try? await Task.sleep(for: .milliseconds(200))
    }
}

actor AntigravitySwitchDatabase {
    private enum DatabaseError: LocalizedError {
        case timeout

        var errorDescription: String? {
            "Database operation timed out. The database may be locked by another process."
        }
    }

    private let databaseURL: URL
    private let backupURL: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    nonisolated static func isRetryableSQLiteResult(_ result: Int32) -> Bool {
        result == SQLITE_BUSY || result == SQLITE_LOCKED
    }

    init() {
        databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        backupURL = databaseURL.appendingPathExtension("quotio.backup")
    }

    func exists() -> Bool { FileManager.default.fileExists(atPath: databaseURL.path) }
    func backupExists() -> Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    func activeEmail() throws -> String? {
        guard exists(), let value = try read("antigravityAuthStatus"),
              let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }

    func hasCredential() -> Bool {
        guard exists(),
              let state = try? read("jetskiStateSync.agentManagerInitState"),
              let credential = try? AntigravityProtobuf.extractLegacyOAuthCredential(from: state) else {
            return false
        }
        return credential.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func createBackup() throws {
        guard exists() else { throw CocoaError(.fileNoSuchFile) }
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: databaseURL, to: backupURL)
    }

    func restoreBackup() throws {
        guard backupExists() else { throw CocoaError(.fileNoSuchFile) }
        try? FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.copyItem(at: backupURL, to: databaseURL)
    }

    func removeBackup() { try? FileManager.default.removeItem(at: backupURL) }
    func cleanupSidecars() {
        try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
    }

    func syncMachineID(_ value: String) throws { try write(value, key: "storage.serviceMachineId") }

    func inject(
        accessToken: String,
        refreshToken: String,
        expiry: Int64,
        email: String,
        format: AntigravityTokenFormat
    ) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try transaction { database in
                    switch format {
                    case .unified:
                        try self.write(
                            AntigravityProtobuf.createUnified(accessToken, refreshToken, expiry),
                            key: "antigravityUnifiedStateSync.oauthToken", database: database)
                    case .legacy:
                        try self.injectLegacy(accessToken, refreshToken, expiry, email, database)
                    case .unknown:
                        try self.write(
                            AntigravityProtobuf.createUnified(accessToken, refreshToken, expiry),
                            key: "antigravityUnifiedStateSync.oauthToken", database: database)
                        try self.injectLegacy(accessToken, refreshToken, expiry, email, database)
                    }
                    try self.write("true", key: "antigravityOnboarding", database: database)
                }
                return
            } catch {
                lastError = error
                guard case DatabaseError.timeout = error, attempt < 3 else { throw error }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func injectLegacy(
        _ access: String, _ refresh: String, _ expiry: Int64, _ email: String,
        _ database: OpaquePointer
    ) throws {
        guard let state = try read("jetskiStateSync.agentManagerInitState", database: database),
              !state.isEmpty else { return }
        try write(
            AntigravityProtobuf.injectLegacy(state, access, refresh, expiry, email),
            key: "jetskiStateSync.agentManagerInitState", database: database)
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard exists() else { throw CocoaError(.fileNoSuchFile) }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        if Self.isRetryableSQLiteResult(result) {
            if let database { sqlite3_close(database) }
            throw DatabaseError.timeout
        }
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        sqlite3_busy_timeout(database, 10_000)
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func transaction(_ body: (OpaquePointer) throws -> Void) throws {
        try withDatabase { database in
            let beginResult = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
            if Self.isRetryableSQLiteResult(beginResult) { throw DatabaseError.timeout }
            guard beginResult == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                try body(database)
                let commitResult = sqlite3_exec(database, "COMMIT", nil, nil, nil)
                if Self.isRetryableSQLiteResult(commitResult) { throw DatabaseError.timeout }
                guard commitResult == SQLITE_OK else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } catch {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    private func read(_ key: String, database: OpaquePointer? = nil) throws -> String? {
        if let database { return try readValue(key, database) }
        return try withDatabase { try readValue(key, $0) }
    }

    private func readValue(_ key: String, _ database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil)
        if Self.isRetryableSQLiteResult(prepareResult) { throw DatabaseError.timeout }
        guard prepareResult == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, Self.transient) }) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            return sqlite3_column_text(statement, 0).map(String.init(cString:))
        case SQLITE_DONE:
            return nil
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw DatabaseError.timeout
        default:
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func write(_ value: String, key: String, database: OpaquePointer? = nil) throws {
        if let database { try writeValue(value, key, database); return }
        try withDatabase { try writeValue(value, key, $0) }
    }

    private func writeValue(_ value: String, _ key: String, _ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database, "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil)
        if Self.isRetryableSQLiteResult(prepareResult) { throw DatabaseError.timeout }
        guard prepareResult == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, Self.transient) }) == SQLITE_OK,
              value.withCString({ sqlite3_bind_text(statement, 2, $0, -1, Self.transient) }) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stepResult = sqlite3_step(statement)
        if Self.isRetryableSQLiteResult(stepResult) { throw DatabaseError.timeout }
        guard stepResult == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}
