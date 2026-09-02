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
final class IDEScanSettingsManager {
    static let shared = IDEScanSettingsManager()
    
    /// Last scan result (not persisted - cleared on app restart)
    var lastScanResult: IDEScanResult?
    
    /// Whether a scan is currently in progress
    var isScanning: Bool = false
    
    /// Last error message from scan
    var lastError: String?
    
    private init() {}
    
    // MARK: - Scan State
    
    /// Clear the last scan result
    func clearScanResult() {
        lastScanResult = nil
        lastError = nil
    }
    
    /// Update scan result
    func updateScanResult(_ result: IDEScanResult) {
        lastScanResult = result
        lastError = nil
    }
    
    /// Set scanning state
    func setScanningState(_ scanning: Bool) {
        isScanning = scanning
        if scanning {
            lastError = nil
        }
    }
    
    /// Set error state
    func setError(_ error: String) {
        lastError = error
        isScanning = false
    }
}
