import AppKit
import Foundation
import QuotioApplication
import QuotioDomain
import SQLite3

public enum AntigravityAccountSwitcherFactory {
    public static func make() -> any AntigravityAccountSwitching {
        AntigravityAccountSwitcher()
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

actor AntigravityAccountSwitcher: AntigravityAccountSwitching {
    private let database = AntigravitySwitchDatabase()
    private let process = AntigravityIDEProcess()
    private let devices = AntigravityDeviceStore()
    private let quota = AntigravityQuotaFetcher()
    private let credentialStore = LocalAntigravityCredentialStore()
    private let now: @Sendable () -> Date
    private var current = AntigravitySwitchSnapshot()
    private var continuations: [UUID: AsyncStream<AntigravitySwitchSnapshot>.Continuation] = [:]
    private var operationID: UUID?

    init(now: @escaping @Sendable () -> Date = Date.init) {
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
        let credentials = await LocalAntigravityCredentialStore(authDirectory: expanded).credentials()
        let credentialPath = credentials.first(where: {
            $0.accountKey.caseInsensitiveCompare(email) == .orderedSame
        }).flatMap { credential -> String? in
            guard case .authFile(let path, _) = credential.origin else { return nil }
            return path
        } ?? Self.authFilePath(email: email, directory: expanded)
        guard let credentialPath else {
            fail("Auth file not found for \(email)")
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
            fail("Failed to read auth file")
            return
        }
        let wasRunning = await process.isRunning()

        do {
            if Self.isExpired(auth.expired, now: now()), let refreshToken = auth.refreshToken {
                let refreshed = try await quota.refreshAccessToken(refreshToken: refreshToken)
                auth.accessToken = refreshed.accessToken
                auth.expired = refreshed.expiresAt.map { ISO8601DateFormatter().string(from: $0) }
                let credential = AntigravityCredential(
                    accountKey: auth.email,
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken ?? refreshToken,
                    expiresAt: refreshed.expiresAt,
                    origin: .authFile(path: path, originalData: data)
                )
                await credentialStore.save(
                    credential,
                    expiresIn: max(0, Int((refreshed.expiresAt ?? now()).timeIntervalSince(now())))
                )
            }
            try ensureCurrent(id)
            let format = await AntigravityVersionDetection.detectFormat()
            if wasRunning { update(.switching(progress: .closingIDE)) }
            _ = await process.terminateAll()
            await database.cleanupSidecars()
            try await Task.sleep(for: wasRunning ? .milliseconds(500) : .milliseconds(200))
            try ensureCurrent(id)

            update(.switching(progress: .creatingBackup))
            try await database.createBackup()
            try ensureCurrent(id)

            update(.switching(progress: .injectingToken))
            let profile = await devices.loadOrCreate(email: auth.email)
            try? await devices.writeToIDE(profile)
            try? await database.syncMachineID(profile.deviceID)
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
                fail(error.localizedDescription)
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

    private func update(_ state: AntigravitySwitchState) {
        current.state = state
        publish()
    }

    private func fail(_ message: String) { update(.failed(message: message)) }

    private func publish() {
        for continuation in continuations.values { continuation.yield(current) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    static func isExpired(_ value: String?, now: Date) -> Bool {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return false }
        return date < now
    }

    static func expiry(_ value: String?, now: Date) -> Int64 {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else {
            return Int64(now.timeIntervalSince1970) + 3_600
        }
        return Int64(date.timeIntervalSince1970)
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
