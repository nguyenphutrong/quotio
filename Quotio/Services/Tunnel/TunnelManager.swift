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
    private static let customPublicURLDefaultsKey = "customTunnelPublicURL"
    
    // MARK: - State
    
    private(set) var tunnelState = CloudflareTunnelState()
    private(set) var installation: CloudflaredInstallation = .notInstalled

    var customPublicURL: String? {
        get {
            Self.normalizedCustomPublicURL(UserDefaults.standard.string(forKey: Self.customPublicURLDefaultsKey))
        }
        set {
            if let normalized = Self.normalizedCustomPublicURL(newValue) {
                UserDefaults.standard.set(normalized, forKey: Self.customPublicURLDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.customPublicURLDefaultsKey)
            }
        }
    }

    var effectivePublicURL: String? {
        if hasCustomTunnelToken, let customPublicURL {
            return customPublicURL
        }
        return tunnelState.publicURL
    }
    
    // MARK: - Private Properties
    
    private let service = CloudflaredService()
    private var monitorTask: Task<Void, Never>?
    private var tunnelRequestId: UInt64 = 0
    private var startTimeoutTask: Task<Void, Never>?
    private let startTimeoutSeconds: TimeInterval = 30
    private var lastPort: UInt16 = 0
    private var autoRestartTask: Task<Void, Never>?
    private let autoRestartDelaySeconds: TimeInterval = 5
    private var autoRestartAttempts: Int = 0
    private let maxAutoRestartAttempts: Int = 3
    private var hasCustomTunnelToken: Bool {
        !(KeychainHelper.getCloudflareTunnelToken()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }
    
    // MARK: - Init
    
    private init() {
        Task {
            await refreshInstallation()
            Self.cleanupOrphans()
        }
    }

    nonisolated static func normalizedCustomPublicURL(_ rawURL: String?) -> String? {
        guard let rawURL else { return nil }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        components.scheme = scheme
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        }

        guard var normalized = components.string else { return nil }
        if normalized.hasSuffix("/") && components.path.isEmpty {
            normalized.removeLast()
        }
        return normalized
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
        let usingCustomToken = hasCustomTunnelToken

        if usingCustomToken && customPublicURL == nil {
            tunnelState.status = .error
            tunnelState.errorMessage = "tunnel.error.customURLRequired".localized()
            return
        }
        
        tunnelState.status = .starting
        tunnelState.errorMessage = nil
        tunnelState.publicURL = nil
        cancelStartTimeout()
        
        do {
            CLIProxyManager.shared.updateConfigAllowRemote(true)

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
                    self.lastPort = port
                    self.cancelStartTimeout()
                    self.cancelAutoRestart()
                    self.resetAutoRestartAttempts()
                    NSLog("[TunnelManager] Tunnel active: %@", url)
                }
            }

            scheduleStartTimeout(requestId: currentRequestId, port: port, allowMissingURL: usingCustomToken)
            startMonitoring()
            
        } catch let error as TunnelError {
            guard tunnelRequestId == currentRequestId else { return }
            tunnelState.status = .error
            tunnelState.errorMessage = error.localizedMessage
            cancelStartTimeout()
            CLIProxyManager.shared.updateConfigAllowRemote(false)
            NSLog("[TunnelManager] Failed to start tunnel: %@", error.localizedMessage)
        } catch {
            guard tunnelRequestId == currentRequestId else { return }
            tunnelState.status = .error
            tunnelState.errorMessage = error.localizedDescription
            cancelStartTimeout()
            CLIProxyManager.shared.updateConfigAllowRemote(false)
            NSLog("[TunnelManager] Failed to start tunnel: %@", error.localizedDescription)
        }
    }
    
    func stopTunnel() async {
        guard tunnelState.status == .active || tunnelState.status == .starting else {
            return
        }
        
        tunnelRequestId &+= 1
        cancelStartTimeout()
        cancelAutoRestart()
        
        tunnelState.status = .stopping
        stopMonitoring()
        
        await service.stop()
        CLIProxyManager.shared.updateConfigAllowRemote(false)

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
        guard let url = effectivePublicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    
    func cleanupOrphans() {
        Self.cleanupOrphans()
    }

    nonisolated static func cleanupOrphans() {
        CloudflaredService.killOrphanProcesses()
    }
    
    // MARK: - Process Monitoring
    
    private func startMonitoring() {
        stopMonitoring()
        
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
                
                guard let self = self else { break }
                
                let isRunning = await self.service.isRunning
                let currentStatus = self.tunnelState.status
                
                if !isRunning && (currentStatus == .active || currentStatus == .starting) {
                    self.tunnelState.status = .error
                    self.tunnelState.errorMessage = "tunnel.error.unexpectedExit".localized()
                    CLIProxyManager.shared.updateConfigAllowRemote(false)
                    NSLog("[TunnelManager] Tunnel process exited unexpectedly")
                    await self.service.stop()
                    self.scheduleAutoRestart()
                    break
                }
            }
        }
    }
    
    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func scheduleStartTimeout(requestId: UInt64, port: UInt16, allowMissingURL: Bool) {
        cancelStartTimeout()
        startTimeoutTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.startTimeoutSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.tunnelRequestId == requestId else { return }
            guard self.tunnelState.status == .starting else { return }

            if allowMissingURL {
                let isRunning = await self.service.isRunning
                guard isRunning else {
                    self.tunnelState.status = .error
                    self.tunnelState.errorMessage = "tunnel.error.startTimeout".localized()
                    CLIProxyManager.shared.updateConfigAllowRemote(false)
                    NSLog("[TunnelManager] Tunnel start timed out after %.0f seconds", self.startTimeoutSeconds)
                    await self.service.stop()
                    return
                }

                self.tunnelState.status = .active
                self.tunnelState.startTime = Date()
                self.lastPort = port
                self.cancelAutoRestart()
                self.resetAutoRestartAttempts()
                NSLog("[TunnelManager] Tunnel active without detected public URL (token mode)")
                return
            }

            self.tunnelState.status = .error
            self.tunnelState.errorMessage = "tunnel.error.startTimeout".localized()
            CLIProxyManager.shared.updateConfigAllowRemote(false)
            NSLog("[TunnelManager] Tunnel start timed out after %.0f seconds", self.startTimeoutSeconds)
            await self.service.stop()
        }
    }

    private func cancelStartTimeout() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
    }
    
    private func scheduleAutoRestart() {
        cancelAutoRestart()
        
        let autoRestartEnabled = UserDefaults.standard.bool(forKey: "autoRestartTunnel")
        guard autoRestartEnabled, lastPort > 0 else { return }
        
        guard autoRestartAttempts < maxAutoRestartAttempts else {
            NSLog("[TunnelManager] Max auto-restart attempts reached (%d), stopping", autoRestartAttempts)
            return
        }
        
        let delay = autoRestartDelaySeconds
        let port = lastPort
        
        NSLog("[TunnelManager] Scheduling auto-restart in %.0f seconds (attempt %d/%d)", delay, autoRestartAttempts + 1, maxAutoRestartAttempts)
        
        autoRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            
            guard self.tunnelState.status == .error || self.tunnelState.status == .idle else {
                NSLog("[TunnelManager] Skipping auto-restart: status is %@", self.tunnelState.status.rawValue)
                return
            }
            
            self.autoRestartAttempts += 1
            NSLog("[TunnelManager] Auto-restarting tunnel on port %d (attempt %d)", port, self.autoRestartAttempts)
            await self.startTunnel(port: port)
        }
    }
    
    private func cancelAutoRestart() {
        autoRestartTask?.cancel()
        autoRestartTask = nil
    }
    
    private func resetAutoRestartAttempts() {
        autoRestartAttempts = 0
    }
}
