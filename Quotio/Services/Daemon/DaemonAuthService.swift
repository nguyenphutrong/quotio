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
