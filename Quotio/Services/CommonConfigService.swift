//
//  CommonConfigService.swift
//  Quotio
//

import Foundation

actor CommonConfigService {
    static let shared = CommonConfigService()
    
    private let storageKeyPrefix = "commonConfig."
    private let fileManager = FileManager.default
    
    private init() {}
    
    // MARK: - Common Fields Definition
    
    private let commonFields: Set<String> = [
        "permissions",
        "hooks",
        "mcpServers",
        "statusLine",
        "plugins",
        "autoUpdaterStatus",
        "projects",
        "preferredNotifChannel"
    ]
    
    private let differentiatingFields: Set<String> = [
        "env",
        "model",
        "primaryApiKey",
        "apiKeyHelper"
    ]
    
    // MARK: - Extract Common Config
    
    func extractCommonConfig(from agent: CLIAgent) throws -> [String: Any] {
        let configPath = agent.configPaths.first ?? ""
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        
        guard fileManager.fileExists(atPath: expandedPath) else {
            throw CommonConfigError.configNotFound(agent.displayName)
        }
        
        let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommonConfigError.invalidJSON
        }
        
        var commonConfig: [String: Any] = [:]
        
        for (key, value) in json {
            if commonFields.contains(key) {
                commonConfig[key] = value
            }
        }
        
        return commonConfig
    }
    
    func extractCommonConfigJSON(from agent: CLIAgent) throws -> String {
        let config = try extractCommonConfig(from: agent)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    
    // MARK: - Apply Common Config
    
    func applyCommonConfig(_ commonConfig: [String: Any], to agent: CLIAgent) throws {
        let configPath = agent.configPaths.first ?? ""
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        
        var existingConfig: [String: Any] = [:]
        
        if fileManager.fileExists(atPath: expandedPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingConfig = json
            }
            
            try createBackup(at: expandedPath)
        }
        
        var mergedConfig = existingConfig
        
        for (key, value) in commonConfig {
            if commonFields.contains(key) {
                mergedConfig[key] = value
            }
        }
        
        let outputData = try JSONSerialization.data(withJSONObject: mergedConfig, options: [.prettyPrinted, .sortedKeys])
        
        let parentDir = (expandedPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        
        try outputData.write(to: URL(fileURLWithPath: expandedPath))
    }
    
    private func createBackup(at path: String) throws {
        let backupPath = path + ".backup"
        
        if fileManager.fileExists(atPath: backupPath) {
            try fileManager.removeItem(atPath: backupPath)
        }
        
        try fileManager.copyItem(atPath: path, toPath: backupPath)
    }
    
    func applyCommonConfigJSON(_ jsonString: String, to agent: CLIAgent) throws {
        guard let data = jsonString.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommonConfigError.invalidJSON
        }
        try applyCommonConfig(config, to: agent)
    }
    
    // MARK: - Stored Snippets
    
    func getStoredSnippet(for agent: CLIAgent) -> String? {
        UserDefaults.standard.string(forKey: storageKeyPrefix + agent.rawValue)
    }
    
    func storeSnippet(_ snippet: String, for agent: CLIAgent) {
        UserDefaults.standard.set(snippet, forKey: storageKeyPrefix + agent.rawValue)
    }
    
    func deleteStoredSnippet(for agent: CLIAgent) {
        UserDefaults.standard.removeObject(forKey: storageKeyPrefix + agent.rawValue)
    }
    
    func hasStoredSnippet(for agent: CLIAgent) -> Bool {
        getStoredSnippet(for: agent) != nil
    }
    
    // MARK: - Merge with Differentiating Fields
    
    func mergeConfigs(common: [String: Any], differentiating: [String: Any]) -> [String: Any] {
        var result = common
        
        for (key, value) in differentiating {
            if let existingDict = result[key] as? [String: Any],
               let newDict = value as? [String: Any] {
                result[key] = existingDict.merging(newDict) { _, new in new }
            } else {
                result[key] = value
            }
        }
        
        return result
    }
    
    // MARK: - Preview
    
    func previewMergedConfig(agent: CLIAgent, withCommon commonConfig: [String: Any]) throws -> String {
        let configPath = agent.configPaths.first ?? ""
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        
        var existingConfig: [String: Any] = [:]
        
        if fileManager.fileExists(atPath: expandedPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingConfig = json
            }
        }
        
        let merged = mergeConfigs(common: existingConfig, differentiating: commonConfig)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Errors

enum CommonConfigError: LocalizedError {
    case configNotFound(String)
    case invalidJSON
    case writeFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .configNotFound(let agent):
            return "Configuration file not found for \(agent)"
        case .invalidJSON:
            return "Invalid JSON format"
        case .writeFailed(let path):
            return "Failed to write configuration to \(path)"
        }
    }
}
