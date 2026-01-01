//
//  AntigravityActiveAccount.swift
//  Quotio
//
//  Model for tracking the currently active Antigravity account in the IDE.
//

import Foundation

/// Represents the currently active Antigravity account in the IDE
struct AntigravityActiveAccount: Equatable, Sendable {
    /// Email or account identifier
    let identifier: String
    
    /// Access token (first 20 chars for comparison, not stored in full for security)
    let tokenPrefix: String
    
    /// When the active account was last detected
    let detectedAt: Date
    
    /// Check if this matches a given auth file based on token prefix
    func matches(accessToken: String) -> Bool {
        accessToken.prefix(20) == tokenPrefix.prefix(20)
    }
}

/// State for account switching operation
enum AccountSwitchState: Equatable {
    case idle
    case confirming(accountId: String, accountEmail: String)
    case switching(progress: SwitchProgress)
    case success(accountId: String)
    case failed(message: String)
    
    enum SwitchProgress: String, Equatable {
        case closingIDE = "Closing Antigravity IDE..."
        case creatingBackup = "Creating backup..."
        case injectingToken = "Injecting token..."
        case restartingIDE = "Restarting Antigravity IDE..."
    }
    
    var isInProgress: Bool {
        if case .switching = self { return true }
        return false
    }
}
