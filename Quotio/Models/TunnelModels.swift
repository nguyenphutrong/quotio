//
//  TunnelModels.swift
//  Quotio - Cloudflare Tunnel Models
//

import Foundation
import SwiftUI

// MARK: - Tunnel Status

enum CloudflareTunnelStatus: String, Sendable {
    case idle
    case starting
    case active
    case stopping
    case error
    
    @MainActor
    var displayName: String {
        switch self {
        case .idle: return "tunnel.status.idle".localized()
        case .starting: return "tunnel.status.starting".localized()
        case .active: return "tunnel.status.active".localized()
        case .stopping: return "tunnel.status.stopping".localized()
        case .error: return "tunnel.status.error".localized()
        }
    }
    
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .starting: return .orange
        case .active: return .green
        case .stopping: return .orange
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .idle: return "globe"
        case .starting: return "arrow.triangle.2.circlepath"
        case .active: return "globe"
        case .stopping: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Tunnel State

@MainActor @Observable
final class CloudflareTunnelState {
    var status: CloudflareTunnelStatus = .idle
    var publicURL: String?
    var errorMessage: String?
    var startTime: Date?
    
    var isActive: Bool { status == .active }
    var isTransitioning: Bool { status == .starting || status == .stopping }
    
    func reset() {
        status = .idle
        publicURL = nil
        errorMessage = nil
        startTime = nil
    }
}

// MARK: - Cloudflared Installation

struct CloudflaredInstallation: Sendable {
    let isInstalled: Bool
    let path: String?
    let version: String?
    
    nonisolated static let notInstalled = CloudflaredInstallation(isInstalled: false, path: nil, version: nil)
}
