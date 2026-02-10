//
//  AntigravityDeviceManager.swift
//  Quotio
//
//  Manages device fingerprint profiles for Antigravity IDE account switching.
//  Each account gets a unique device profile written to storage.json to prevent
//  session conflicts when switching between accounts.
//

import Foundation

actor AntigravityDeviceManager {
    
    // MARK: - Types
    
    struct DeviceProfile: Codable, Sendable {
        let machineId: String
        let macMachineId: String
        let devDeviceId: String
        let sqmId: String
    }
    
    // MARK: - Paths
    
    private static let storagePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/storage.json")
    
    private static let profileStorageDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".quotio/antigravity-profiles")
    
    // MARK: - Profile Generation
    
    static func generateProfile() -> DeviceProfile {
        DeviceProfile(
            machineId: "auth0|user_\(randomHex(length: 32))",
            macMachineId: generateUUIDv4Style(),
            devDeviceId: UUID().uuidString.lowercased(),
            sqmId: "{\(UUID().uuidString.uppercased())}"
        )
    }
    
    private static func randomHex(length: Int) -> String {
        let chars = "0123456789abcdef"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
    
    private static func generateUUIDv4Style() -> String {
        // xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx (y in 8..b)
        let hex = "0123456789abcdef"
        var result = ""
        for ch in "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" {
            switch ch {
            case "-", "4":
                result.append(ch)
            case "y":
                let yChars = ["8", "9", "a", "b"]
                result.append(yChars.randomElement()!)
            default:
                result.append(hex.randomElement()!)
            }
        }
        return result
    }
    
    // MARK: - Profile Persistence (per-account)
    
    func loadOrCreateProfile(forEmail email: String) -> DeviceProfile {
        if let existing = loadProfile(forEmail: email) {
            return existing
        }
        let profile = Self.generateProfile()
        saveProfile(profile, forEmail: email)
        return profile
    }
    
    private func profilePath(forEmail email: String) -> URL {
        let sanitized = email.replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return Self.profileStorageDir.appendingPathComponent("\(sanitized).json")
    }
    
    private func loadProfile(forEmail email: String) -> DeviceProfile? {
        let path = profilePath(forEmail: email)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(DeviceProfile.self, from: data)
    }
    
    private func saveProfile(_ profile: DeviceProfile, forEmail email: String) {
        let dir = Self.profileStorageDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let path = profilePath(forEmail: email)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: path)
    }
    
    // MARK: - Storage.json Write
    
    func writeProfileToStorage(_ profile: DeviceProfile) throws {
        let storagePath = Self.storagePath
        guard FileManager.default.fileExists(atPath: storagePath.path) else {
            Log.warning("storage.json not found, skipping device profile injection")
            return
        }
        
        let content = try String(contentsOf: storagePath, encoding: .utf8)
        guard let jsonData = content.data(using: .utf8),
              var json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            Log.error("Failed to parse storage.json")
            return
        }
        
        // Nested telemetry object
        var telemetry = (json["telemetry"] as? [String: Any]) ?? [:]
        telemetry["machineId"] = profile.machineId
        telemetry["macMachineId"] = profile.macMachineId
        telemetry["devDeviceId"] = profile.devDeviceId
        telemetry["sqmId"] = profile.sqmId
        json["telemetry"] = telemetry
        
        // Flat telemetry keys (backward compat)
        json["telemetry.machineId"] = profile.machineId
        json["telemetry.macMachineId"] = profile.macMachineId
        json["telemetry.devDeviceId"] = profile.devDeviceId
        json["telemetry.sqmId"] = profile.sqmId
        
        // serviceMachineId at root level (matches devDeviceId)
        json["storage.serviceMachineId"] = profile.devDeviceId
        
        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: storagePath)
        
        Log.debug("Device profile written to storage.json")
    }
}
