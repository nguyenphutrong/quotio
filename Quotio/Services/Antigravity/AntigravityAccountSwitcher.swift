//
//  AntigravityAccountSwitcher.swift
//  Quotio
//
//  Orchestrates the account switching flow for Antigravity IDE.
//  Coordinates database backup, token injection, and IDE restart.
//

import Foundation

/// Orchestrates Antigravity account switching with proper error handling and rollback
@MainActor
@Observable
final class AntigravityAccountSwitcher {
    
    // MARK: - Singleton
    
    static let shared = AntigravityAccountSwitcher()
    private init() {}
    
    // MARK: - Dependencies
    // Lazy-load database service only when needed (saves memory if Antigravity not installed)
    private var _databaseService: AntigravityDatabaseService?
    private var databaseService: AntigravityDatabaseService {
        if let service = _databaseService {
            return service
        }
        let service = AntigravityDatabaseService()
        _databaseService = service
        return service
    }
    private let processManager = AntigravityProcessManager.shared
    private let quotaFetcher = AntigravityQuotaFetcher()
    private let deviceManager = AntigravityDeviceManager()
    
    // MARK: - State
    
    var switchState: AccountSwitchState = .idle
    var currentActiveAccount: AntigravityActiveAccount?
    
    // MARK: - Errors
    
    enum SwitchError: LocalizedError {
        case authFileNotFound(String)
        case tokenReadFailed(String)
        case ideRunningAndUserCancelled
        case databaseError(Error)
        case processError(Error)
        
        var errorDescription: String? {
            switch self {
            case .authFileNotFound(let path):
                return "Auth file not found: \(path)"
            case .tokenReadFailed(let reason):
                return "Failed to read token: \(reason)"
            case .ideRunningAndUserCancelled:
                return "IDE is running and user cancelled the switch"
            case .databaseError(let error):
                return "Database error: \(error.localizedDescription)"
            case .processError(let error):
                return "Process error: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Check if Antigravity IDE database exists
    func isDatabaseAvailable() async -> Bool {
        await databaseService.databaseExists()
    }
    
    /// Check if Antigravity IDE is currently running
    func isIDERunning() -> Bool {
        processManager.isRunning()
    }
    
    /// Detect the currently active account in Antigravity IDE
    /// Reads email directly from antigravityAuthStatus in the database
    func detectActiveAccount() async {
        do {
            guard let activeEmail = try await databaseService.getActiveEmail(),
                  !activeEmail.isEmpty else {
                currentActiveAccount = nil
                return
            }
            
            currentActiveAccount = AntigravityActiveAccount(
                email: activeEmail,
                detectedAt: Date()
            )
        } catch {
            currentActiveAccount = nil
        }
    }
    
    /// Check if a given email matches the currently active account
    func isActiveAccount(email: String) -> Bool {
        guard let active = currentActiveAccount else { return false }
        return active.matches(email: email)
    }
    
    /// Begin the account switch confirmation flow
    func beginSwitch(accountId: String, accountEmail: String) {
        switchState = .confirming(accountId: accountId, accountEmail: accountEmail)
    }
    
    /// Cancel the current switch operation
    func cancelSwitch() {
        switchState = .idle
    }
    
    /// Execute the account switch
    /// - Parameters:
    ///   - authFilePath: Path to the Antigravity auth file (e.g., ~/.cli-proxy-api/antigravity-user@gmail.com.json)
    ///   - shouldRestartIDE: Whether to restart the IDE after injection (only if it was running)
    func executeSwitch(authFilePath: String, shouldRestartIDE: Bool = true) async {
        let url = URL(fileURLWithPath: (authFilePath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              var authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data) else {
            switchState = .failed(message: "Failed to read auth file")
            return
        }

        let wasIDERunning = processManager.isRunning()

        do {
            // Step 0: Ensure token is fresh
            if authFile.isExpired, let refreshToken = authFile.refreshToken {
                do {
                    let freshToken = try await quotaFetcher.refreshAccessToken(refreshToken: refreshToken)
                    authFile.accessToken = freshToken
                    authFile.expired = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))

                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    if let updatedData = try? encoder.encode(authFile) {
                        try updatedData.write(to: url)
                    }
                } catch {
                    switchState = .failed(message: "Token refresh failed: \(error.localizedDescription)")
                    return
                }
            }

            // Check cancellation before proceeding
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 1: Detect version format before closing IDE
            let versionFormat = AntigravityVersionDetector.detectFormat()

            // Step 2: Close IDE if running
            if wasIDERunning {
                switchState = .switching(progress: .closingIDE)
            }
            _ = await processManager.terminateAllProcesses()

            await databaseService.cleanupWALFiles()

            let settleDelay: UInt64 = wasIDERunning ? 500_000_000 : 200_000_000
            try? await Task.sleep(nanoseconds: settleDelay)

            // Check cancellation after IDE close
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 3: Create backup
            switchState = .switching(progress: .creatingBackup)
            try await databaseService.createBackup()

            // Check cancellation
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 4: Inject device profile into storage.json
            switchState = .switching(progress: .injectingToken)

            let deviceProfile = await deviceManager.loadOrCreateProfile(forEmail: authFile.email)
            do {
                try await deviceManager.writeProfileToStorage(deviceProfile)
                try await databaseService.syncServiceMachineId(deviceProfile.devDeviceId)
            } catch {
                Log.warning("Device profile injection failed (non-fatal): \(error)")
            }

            // Check cancellation
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 5: Inject token (version-aware)
            let expiry: Int64
            if let expired = authFile.expired,
               let expiryDate = ISO8601DateFormatter().date(from: expired) {
                expiry = Int64(expiryDate.timeIntervalSince1970)
            } else {
                expiry = Int64(Date().timeIntervalSince1970) + 3600
            }

            try await databaseService.injectToken(
                accessToken: authFile.accessToken,
                refreshToken: authFile.refreshToken ?? "",
                expiry: expiry,
                email: authFile.email,
                versionFormat: versionFormat
            )

            // Check cancellation
            guard !Task.isCancelled else {
                switchState = .idle
                return
            }

            // Step 6: Restart IDE if it was running
            if wasIDERunning && shouldRestartIDE {
                switchState = .switching(progress: .restartingIDE)
                try await processManager.launch()
            }

            // Step 7: Clean up
            await databaseService.removeBackup()

            currentActiveAccount = AntigravityActiveAccount(
                email: authFile.email,
                detectedAt: Date()
            )

            let accountId = url.lastPathComponent
                .replacingOccurrences(of: "antigravity-", with: "")
                .replacingOccurrences(of: ".json", with: "")

            switchState = .success(accountId: accountId)
            
        } catch {
            if await databaseService.backupExists() {
                do {
                    try await databaseService.restoreFromBackup()
                } catch {
                    Log.error("Rollback failed: \(error)")
                }
            }
            
            switchState = .failed(message: error.localizedDescription)
        }
    }
    
    /// Execute switch using account email to find the auth file
    func executeSwitchForEmail(_ email: String, authDir: String = "~/.cli-proxy-api") async {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        
        // Build expected filename: antigravity-user@gmail.com.json
        let sanitizedEmail = email
            .replacingOccurrences(of: "@", with: ".")
            .replacingOccurrences(of: ".", with: "_")
        
        // Try different filename patterns
        let possibleFilenames = [
            "antigravity-\(email).json",
            "antigravity-\(sanitizedEmail).json",
            "antigravity-\(email.replacingOccurrences(of: "@gmail.com", with: ".gmail.com").replacingOccurrences(of: ".", with: "_")).json"
        ]
        
        var foundPath: String?
        for filename in possibleFilenames {
            let path = (expandedPath as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: path) {
                foundPath = path
                break
            }
        }
        
        // If not found by email, scan directory
        if foundPath == nil {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: expandedPath) {
                for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
                    let filePath = (expandedPath as NSString).appendingPathComponent(file)
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                       let authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data),
                       authFile.email == email {
                        foundPath = filePath
                        break
                    }
                }
            }
        }
        
        guard let authFilePath = foundPath else {
            switchState = .failed(message: "Auth file not found for \(email)")
            return
        }
        
        await executeSwitch(authFilePath: authFilePath)
    }
    
    /// Retry the last failed switch
    func retrySwitch() async {
        guard case .failed = switchState else { return }
        // Reset and let UI trigger a new switch
        switchState = .idle
    }
    
    /// Dismiss success/failure state
    func dismissResult() {
        switchState = .idle
    }
}
