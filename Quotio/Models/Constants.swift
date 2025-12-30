//
//  Constants.swift
//  Quotio
//
//  App-wide constants and configuration values.
//

import Foundation

/// App-wide constants
enum AppConstants {
    
    // MARK: - Proxy Version Management
    
    /// Maximum number of proxy versions to keep installed.
    /// Older versions beyond this limit will be automatically deleted after upgrades.
    static let maxInstalledVersions = 3
    
    // MARK: - Network
    
    /// Default proxy port
    static let defaultProxyPort: UInt16 = 17080
    
    // MARK: - UI
    
    /// Maximum number of items to display in menu bar
    static let maxMenuBarItems = 3
}
