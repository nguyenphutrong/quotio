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
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            tokens = try JSONDecoder().decode([WarpToken].self, from: data)
        } catch {
            print("Failed to load Warp tokens: \(error)")
        }
    }
    
    private func saveTokens() {
        do {
            let data = try JSONEncoder().encode(tokens)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save Warp tokens: \(error)")
        }
    }
}
