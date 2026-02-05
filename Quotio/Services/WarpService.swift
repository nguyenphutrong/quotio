//
//  WarpService.swift
//  Quotio
//
//  Service for managing Warp AI connection tokens.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class WarpService {
    static let shared = WarpService()
    
    private(set) var tokens: [WarpToken] = []
    private let storageKey = "warpTokens"
    
    private init() {
        loadTokens()
    }
    
    struct WarpToken: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        var name: String
        var token: String
        var isEnabled: Bool
        
        init(id: UUID = UUID(), name: String, token: String, isEnabled: Bool = true) {
            self.id = id
            self.name = name
            self.token = token
            self.isEnabled = isEnabled
        }
    }
    
    func addToken(name: String, token: String) {
        let newToken = WarpToken(name: name, token: token)
        tokens.append(newToken)
        saveTokens()
    }
    
    func updateToken(_ token: WarpToken) {
        if let index = tokens.firstIndex(where: { $0.id == token.id }) {
            tokens[index] = token
            saveTokens()
        }
    }
    
    func deleteToken(id: UUID) {
        tokens.removeAll { $0.id == id }
        saveTokens()
    }
    
    func toggleToken(id: UUID) {
        if let index = tokens.firstIndex(where: { $0.id == id }) {
            tokens[index].isEnabled.toggle()
            saveTokens()
        }
    }
    
    private func loadTokens() {
        guard let data = KeychainHelper.getWarpTokens() else { return }
        do {
            tokens = try JSONDecoder().decode([WarpToken].self, from: data)
        } catch {
            Log.keychain("Failed to load Warp tokens: \(error)")
        }
    }
    
    private func saveTokens() {
        do {
            let data = try JSONEncoder().encode(tokens)
            if KeychainHelper.saveWarpTokens(data) {
                UserDefaults.standard.removeObject(forKey: storageKey)
            } else {
                Log.keychain("Failed to persist Warp tokens, using in-memory value")
            }
        } catch {
            Log.keychain("Failed to save Warp tokens: \(error)")
        }
    }
}
