//
//  IDEScanSettings.swift
//  Quotio - IDE Scan Consent and Settings
//
//  Manages user consent for scanning IDE data files
//  Required for privacy: user must explicitly opt-in to scan
//

import Foundation
import QuotioDomain

/// Manages IDE scan consent settings
/// User must explicitly trigger scan - no auto-scanning
@MainActor
@Observable
public final class IDEScanSettingsManager {
    /// Last scan result (not persisted - cleared on app restart)
    public var lastScanResult: IDEScanResult?
    
    /// Whether a scan is currently in progress
    public var isScanning: Bool = false
    
    /// Last error message from scan
    public var lastError: String?
    
    public init() {}
    
    // MARK: - Scan State
    
    /// Clear the last scan result
    public func clearScanResult() {
        lastScanResult = nil
        lastError = nil
    }
    
    /// Update scan result
    public func updateScanResult(_ result: IDEScanResult) {
        lastScanResult = result
        lastError = nil
    }
    
    /// Set scanning state
    public func setScanningState(_ scanning: Bool) {
        isScanning = scanning
        if scanning {
            lastError = nil
        }
    }
    
    /// Set error state
    public func setError(_ error: String) {
        lastError = error
        isScanning = false
    }
}
