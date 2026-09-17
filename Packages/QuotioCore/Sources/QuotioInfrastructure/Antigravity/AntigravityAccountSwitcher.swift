import AppKit
import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3

public enum AntigravityAccountSwitcherFactory {
    public static func make(logger: any ApplicationLogging) -> any AntigravityAccountSwitching {
        AntigravityAccountSwitcher(logger: logger)
    }
}

private struct AntigravitySwitchAuthFile: Decodable, Sendable {
    var accessToken: String
    let refreshToken: String?
    var expired: String?
    let email: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expired
        case email
    }
}

private struct AntigravityTokenRefresh: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

actor AntigravityAccountSwitcher: AntigravityAccountSwitching {
    private let database: AntigravitySwitchDatabase
    private let process = AntigravityIDEProcess()
    private let logger: any ApplicationLogging
    private let machineIdentitySync: @Sendable (String) async throws -> Void
    private let now: @Sendable () -> Date
    private var current = AntigravitySwitchSnapshot()
    private var continuations: [UUID: AsyncStream<AntigravitySwitchSnapshot>.Continuation] = [:]
    private var operationID: UUID?

    init(
        logger: any ApplicationLogging,
        now: @escaping @Sendable () -> Date = Date.init,
        machineIdentitySync: (@Sendable (String) async throws -> Void)? = nil
    ) {
        let database = AntigravitySwitchDatabase()
        let devices = AntigravityDeviceStore()
        self.database = database
        self.logger = logger
        self.machineIdentitySync = machineIdentitySync ?? { email in
            let profile = await devices.loadOrCreate(email: email)
            try await devices.writeToIDE(profile)
            try await database.syncMachineID(profile.deviceID)
        }
        self.now = now
    }

    func snapshots() -> AsyncStream<AntigravitySwitchSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AntigravitySwitchSnapshot.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        continuation.yield(current)
        return stream
    }

    func snapshot() -> AntigravitySwitchSnapshot { current }

    func isAvailable() async -> Bool { await database.exists() }

    func isIDERunning() async -> Bool { await process.isRunning() }

    func detectActiveAccount() async -> AntigravityActiveAccount? {
        let active = try? await database.activeEmail().map {
            AntigravityActiveAccount(email: $0, detectedAt: now())
        }
        current.activeAccount = active ?? nil
        publish()
        return current.activeAccount
    }

    func cancelSwitch() {
        operationID = nil
        current.state = .idle
        publish()
    }

    func switchAccount(email: String, authDirectory: String, restartIDE: Bool) async {
        let expanded = NSString(string: authDirectory).expandingTildeInPath
        let credentialPath = Self.authFilePath(email: email, directory: expanded)
        guard let credentialPath else {
            fail(.authFileNotFound(accountEmail: email))
            return
        }
        await switchAccount(authFilePath: credentialPath, restartIDE: restartIDE)
    }

    func switchAccount(authFilePath: String, restartIDE: Bool) async {
        let id = UUID()
        operationID = id
        let path = NSString(string: authFilePath).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var auth = try? JSONDecoder().decode(AntigravitySwitchAuthFile.self, from: data) else {
            fail(.authFileUnreadable)
            return
        }
        let wasRunning = await process.isRunning()
        var pendingFailure = AntigravitySwitchFailure.credentialRefreshFailed

        do {
            if Self.isExpired(auth.expired, now: now()), let refreshToken = auth.refreshToken {
                let refreshed = try await Self.refreshAccessToken(refreshToken)
                auth.accessToken = refreshed.accessToken
                let expiresIn = refreshed.expiresIn ?? 3_600
                let expiresAt = now().addingTimeInterval(TimeInterval(expiresIn))
                auth.expired = ISO8601DateFormatter().string(from: expiresAt)
                try Self.saveRefreshedAuthFile(
                    path: path,
                    originalData: data,
                    accessToken: refreshed.accessToken,
                    expiresAt: expiresAt,
                    expiresIn: expiresIn
                )
            }
            try ensureCurrent(id)
            let format = await AntigravityVersionDetection.detectFormat()
            if wasRunning { update(.switching(progress: .closingIDE)) }
            _ = await process.terminateAll()
            await database.cleanupSidecars()
            try await Task.sleep(for: wasRunning ? .milliseconds(500) : .milliseconds(200))
            try ensureCurrent(id)

            pendingFailure = .databaseBackupFailed
            update(.switching(progress: .creatingBackup))
            try await database.createBackup()
            try ensureCurrent(id)

            pendingFailure = .credentialInjectionFailed
            update(.switching(progress: .injectingToken))
            await synchronizeMachineIdentity(for: auth.email)
            try ensureCurrent(id)

            let expiry = Self.expiry(auth.expired, now: now())
            try await database.inject(
                accessToken: auth.accessToken,
                refreshToken: auth.refreshToken ?? "",
                expiry: expiry,
                email: auth.email,
                format: format
            )
            try ensureCurrent(id)

            if wasRunning && restartIDE {
                pendingFailure = .ideRestartFailed
                update(.switching(progress: .restartingIDE))
                try await process.launch()
            }
            await database.removeBackup()
            operationID = nil
            current.activeAccount = AntigravityActiveAccount(email: auth.email, detectedAt: now())
            let accountID = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "antigravity-", with: "")
            update(.success(accountID: accountID))
        } catch is CancellationError {
            await rollbackIfNeeded()
            if operationID == id { cancelSwitch() }
        } catch {
            await rollbackIfNeeded()
            if operationID == id {
                operationID = nil
                fail(pendingFailure)
            }
        }
    }

    private func rollbackIfNeeded() async {
        if await database.backupExists() { try? await database.restoreBackup() }
    }

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }

    func synchronizeMachineIdentity(for email: String) async {
        do {
            try await machineIdentitySync(email)
        } catch {
            await logger.write(
                .warning,
                message: "Antigravity machine identity synchronization failed: \(error.localizedDescription)"
            )
        }
    }

    private func update(_ state: AntigravitySwitchState) {
        current.state = state
        publish()
    }

    private func fail(_ failure: AntigravitySwitchFailure) { update(.failed(failure)) }

    private func publish() {
        for continuation in continuations.values { continuation.yield(current) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    static func isExpired(_ value: String?, now: Date) -> Bool {
        guard let date = expiryDate(value) else { return true }
        return date < now
    }

    static func expiry(_ value: String?, now: Date) -> Int64 {
        guard let date = expiryDate(value) else {
            return Int64(now.timeIntervalSince1970) + 3_600
        }
        return Int64(date.timeIntervalSince1970)
    }

    private static func expiryDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func authFilePath(email: String, directory: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        for name in names.sorted() where name.hasPrefix("antigravity-") && name.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(name)
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? Data(contentsOf: url),
                  let auth = try? JSONDecoder().decode(AntigravitySwitchAuthFile.self, from: data),
                  auth.email.caseInsensitiveCompare(email) == .orderedSame else { continue }
            return path
        }
        return nil
    }

    private static func refreshAccessToken(_ refreshToken: String) async throws -> AntigravityTokenRefresh {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let values = [
            "client_id": "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
            "client_secret": "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",
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = values
            .map { "\(form($0.key))=\(form($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let session = URLSession(configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AntigravityTokenRefresh.self, from: data)
    }

    private static func saveRefreshedAuthFile(
        path: String,
        originalData: Data,
        accessToken: String,
        expiresAt: Date,
        expiresIn: Int
    ) throws {
        let url = URL(fileURLWithPath: path)
        guard try Data(contentsOf: url) == originalData,
              var json = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
            throw CocoaError(.fileWriteFileExists)
        }
        json["access_token"] = accessToken
        json["expired"] = ISO8601DateFormatter().string(from: expiresAt)
        json["expires_in"] = expiresIn
        json["timestamp"] = Int64(Date().timeIntervalSince1970 * 1_000)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try SecureAtomicFileWriter.write(data, to: url)
    }

    private static func form(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        ) ?? value
    }
}

private actor AntigravityDeviceStore {
    private let files = FileManager.default
    private let profileDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".quotio/antigravity-profiles")
    private let storageURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/storage.json")

    func loadOrCreate(email: String) -> AntigravityDeviceProfile {
        let url = profileURL(email: email)
        if let data = try? Data(contentsOf: url),
           let profile = try? JSONDecoder().decode(AntigravityDeviceProfile.self, from: data) {
            return profile
        }
        let profile = AntigravityDeviceProfile(
            machineID: "auth0|user_\(Self.randomHex(count: 32))",
            macMachineID: UUID().uuidString.lowercased(),
            deviceID: UUID().uuidString.lowercased(),
            sqmID: "{\(UUID().uuidString.uppercased())}"
        )
        try? files.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profile) { try? data.write(to: url, options: .atomic) }
        return profile
    }

    func writeToIDE(_ profile: AntigravityDeviceProfile) throws {
        guard files.fileExists(atPath: storageURL.path) else { return }
        let data = try Data(contentsOf: storageURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var telemetry = json["telemetry"] as? [String: Any] ?? [:]
        telemetry["machineId"] = profile.machineID
        telemetry["macMachineId"] = profile.macMachineID
        telemetry["devDeviceId"] = profile.deviceID
        telemetry["sqmId"] = profile.sqmID
        json["telemetry"] = telemetry
        json["telemetry.machineId"] = profile.machineID
        json["telemetry.macMachineId"] = profile.macMachineID
        json["telemetry.devDeviceId"] = profile.deviceID
        json["telemetry.sqmId"] = profile.sqmID
        json["storage.serviceMachineId"] = profile.deviceID
        let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: storageURL, options: .atomic)
    }

    private func profileURL(email: String) -> URL {
        let name = email.replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return profileDirectory.appendingPathComponent("\(name).json")
    }

    private static func randomHex(count: Int) -> String {
        let characters = Array("0123456789abcdef")
        return String((0..<count).map { _ in characters.randomElement()! })
    }
}
