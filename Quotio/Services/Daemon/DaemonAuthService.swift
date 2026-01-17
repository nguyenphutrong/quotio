//
//  DaemonAuthService.swift
//  Quotio
//

import Foundation

@MainActor @Observable
final class DaemonAuthService {
    static let shared = DaemonAuthService()
    
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var authAccounts: [IPCAuthAccount] = []
    private(set) var oauthState: DaemonOAuthState?
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func listAuthFiles(provider: String? = nil) async -> [IPCAuthAccount] {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return []
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.listAuth(provider: provider)
            authAccounts = result.accounts
            return result.accounts
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }
    
    func deleteAuthFile(name: String) async throws {
        guard await isDaemonReady else {
            throw DaemonAuthError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.deleteAuth(name: name)
            if !result.success {
                throw DaemonAuthError.deleteFailed
            }
            authAccounts.removeAll { $0.name == name }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func startOAuth(provider: AIProvider, projectId: String? = nil) async throws -> DaemonOAuthState {
        guard await isDaemonReady else {
            throw DaemonAuthError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.startOAuth(
                provider: provider.rawValue,
                projectId: projectId,
                isWebUI: true
            )
            
            let state = DaemonOAuthState(
                url: result.url,
                state: result.state,
                provider: provider,
                status: .pending
            )
            oauthState = state
            return state
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func pollOAuthStatus(state: String) async throws -> DaemonOAuthPollResult {
        guard await isDaemonReady else {
            throw DaemonAuthError.daemonNotRunning
        }
        
        do {
            let result = try await ipcClient.pollOAuthStatus(state: state)
            
            let status: DaemonOAuthStatus
            switch result.status {
            case "completed", "success":
                status = .completed
            case "failed", "error":
                status = .failed
            case "expired":
                status = .expired
            default:
                status = .pending
            }
            
            if status == .completed || status == .failed || status == .expired {
                oauthState = nil
            }
            
            return DaemonOAuthPollResult(
                status: status,
                email: result.email,
                error: result.error
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func cancelOAuth() {
        oauthState = nil
    }
    
    // MARK: - Copilot Device Code Authentication
    
    func startCopilotAuth() async -> CopilotAuthResult {
        guard await isDaemonReady else {
            return CopilotAuthResult(success: false, message: "Daemon not running")
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.copilotStartDeviceCode()
            
            if result.success {
                return CopilotAuthResult(
                    success: true,
                    deviceCode: result.userCode,
                    message: "Please complete authentication in browser"
                )
            } else {
                return CopilotAuthResult(
                    success: false,
                    message: result.error ?? "Failed to start Copilot authentication"
                )
            }
        } catch {
            lastError = error.localizedDescription
            return CopilotAuthResult(success: false, message: error.localizedDescription)
        }
    }
    
    // MARK: - Kiro Authentication
    
    func startKiroAuth(method: AuthCommand) async -> KiroAuthResult {
        guard await isDaemonReady else {
            return KiroAuthResult(success: false, message: "Daemon not running")
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            switch method {
            case .kiroGoogleLogin:
                let result = try await ipcClient.kiroStartGoogle()
                // Kiro Google OAuth returns a URL to open, not a device code
                return KiroAuthResult(
                    success: result.success,
                    deviceCode: nil,
                    message: result.success ? "Check browser for login" : (result.error ?? "Failed to start Google auth")
                )
                
            case .kiroAWSLogin:
                let result = try await ipcClient.kiroStartAws()
                return KiroAuthResult(
                    success: result.success,
                    deviceCode: result.userCode,
                    message: result.success ? "Check browser for AWS SSO" : (result.error ?? "Failed to start AWS auth")
                )
                
            case .kiroImport:
                let result = try await ipcClient.kiroImport()
                return KiroAuthResult(
                    success: result.success,
                    message: result.success ? "Imported \(result.imported) account(s)" : (result.error ?? "Import failed")
                )
                
            default:
                return KiroAuthResult(success: false, message: "Unsupported Kiro auth method")
            }
        } catch {
            lastError = error.localizedDescription
            return KiroAuthResult(success: false, message: error.localizedDescription)
        }
    }
}

struct DaemonOAuthState: Sendable {
    let url: String
    let state: String
    let provider: AIProvider
    var status: DaemonOAuthStatus
}

enum DaemonOAuthStatus: String, Sendable {
    case pending
    case completed
    case failed
    case expired
}

struct DaemonOAuthPollResult: Sendable {
    let status: DaemonOAuthStatus
    let email: String?
    let error: String?
}

// MARK: - Copilot Auth Result

struct CopilotAuthResult {
    let success: Bool
    var deviceCode: String?
    let message: String
}

// MARK: - Kiro Auth Result

struct KiroAuthResult {
    let success: Bool
    var deviceCode: String?
    let message: String
}

enum DaemonAuthError: LocalizedError {
    case daemonNotRunning
    case deleteFailed
    case oauthFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .deleteFailed:
            return "Failed to delete auth file"
        case .oauthFailed(let reason):
            return "OAuth failed: \(reason)"
        }
    }
}
