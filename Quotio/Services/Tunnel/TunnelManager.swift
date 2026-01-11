//
//  TunnelManager.swift
//  Quotio - Cloudflare Tunnel UI State Manager
//

import Foundation
import AppKit

@MainActor
@Observable
final class TunnelManager {
    static let shared = TunnelManager()
    
    // MARK: - State
    
    private(set) var tunnelState = CloudflareTunnelState()
    private(set) var installation: CloudflaredInstallation = .notInstalled
    
    // MARK: - Private Properties
    
    private let service = CloudflaredService()
    private var monitorTask: Task<Void, Never>?
    private var tunnelRequestId: UInt64 = 0
    
    // MARK: - Init
    
    private init() {
        Task {
            await refreshInstallation()
            cleanupOrphans()
        }
    }
    
    // MARK: - Public API
    
    func refreshInstallation() async {
        installation = service.detectInstallation()
    }
    
    func startTunnel(port: UInt16) async {
        guard tunnelState.status == .idle || tunnelState.status == .error else {
            NSLog("[TunnelManager] Cannot start tunnel: status is %@", tunnelState.status.rawValue)
            return
        }
        
        guard installation.isInstalled else {
            tunnelState.status = .error
            tunnelState.errorMessage = "tunnel.error.notInstalled".localized()
            return
        }
        
        tunnelRequestId &+= 1
        let currentRequestId = tunnelRequestId
        
        tunnelState.status = .starting
        tunnelState.errorMessage = nil
        tunnelState.publicURL = nil
        
        do {
            try await service.start(port: port) { [weak self] url in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.tunnelRequestId == currentRequestId else {
                        NSLog("[TunnelManager] Ignoring stale callback for request %llu (current: %llu)", currentRequestId, self.tunnelRequestId)
                        return
                    }
                    self.tunnelState.publicURL = url
                    self.tunnelState.status = .active
                    self.tunnelState.startTime = Date()
                    NSLog("[TunnelManager] Tunnel active: %@", url)
                }
            }
            
            startMonitoring()
            
        } catch let error as TunnelError {
            guard tunnelRequestId == currentRequestId else { return }
            tunnelState.status = .error
            tunnelState.errorMessage = error.localizedMessage
            NSLog("[TunnelManager] Failed to start tunnel: %@", error.localizedMessage)
        } catch {
            guard tunnelRequestId == currentRequestId else { return }
            tunnelState.status = .error
            tunnelState.errorMessage = error.localizedDescription
            NSLog("[TunnelManager] Failed to start tunnel: %@", error.localizedDescription)
        }
    }
    
    func stopTunnel() async {
        guard tunnelState.status == .active || tunnelState.status == .starting else {
            return
        }
        
        tunnelRequestId &+= 1
        
        tunnelState.status = .stopping
        stopMonitoring()
        
        await service.stop()
        
        tunnelState.reset()
        NSLog("[TunnelManager] Tunnel stopped")
    }
    
    func toggle(port: UInt16) async {
        if tunnelState.isActive || tunnelState.status == .starting {
            await stopTunnel()
        } else {
            await startTunnel(port: port)
        }
    }
    
    func copyURLToClipboard() {
        guard let url = tunnelState.publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    
    func cleanupOrphans() {
        CloudflaredService.killOrphanProcesses()
    }
    
    // MARK: - Process Monitoring
    
    private func startMonitoring() {
        stopMonitoring()
        
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                
                guard let self = self else { break }
                
                let isRunning = await self.service.isRunning
                let currentStatus = self.tunnelState.status
                
                if !isRunning && (currentStatus == .active || currentStatus == .starting) {
                    self.tunnelState.status = .error
                    self.tunnelState.errorMessage = "tunnel.error.unexpectedExit".localized()
                    NSLog("[TunnelManager] Tunnel process exited unexpectedly")
                    await self.service.stop()
                    break
                }
            }
        }
    }
    
    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}
