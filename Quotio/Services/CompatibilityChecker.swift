//
//  CompatibilityChecker.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for validating proxy is responding before activation.
//

import Foundation

/// Service for checking proxy compatibility with Quotio.
/// Simplified to just verify proxy responds to API requests.
actor CompatibilityChecker {
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Compatibility Check
    
    /// Check if a running proxy is responding to API requests.
    /// - Parameters:
    ///   - port: The port the proxy is running on
    ///   - host: The host (defaults to 127.0.0.1)
    /// - Returns: Compatibility check result
    func checkCompatibility(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> CompatibilityCheckResult {
        let baseURL = "http://\(host):\(port)"
        
        // Try to call a simple management endpoint
        do {
            let isResponding = try await checkManagementEndpoint(baseURL: baseURL, managementKey: managementKey)
            return isResponding ? .compatible : .proxyNotResponding
        } catch {
            return .connectionError(error.localizedDescription)
        }
    }
    
    /// Check if a proxy is running and healthy.
    /// - Parameters:
    ///   - port: The port to check
    ///   - host: The host (defaults to 127.0.0.1)
    /// - Returns: true if the proxy responds
    func isHealthy(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> Bool {
        let baseURL = "http://\(host):\(port)"
        
        guard let request = makeManagementRequest(baseURL: baseURL, managementKey: managementKey) else {
            return false
        }
        
        do {
            let (_, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            
            return 200...299 ~= httpResponse.statusCode
        } catch {
            return false
        }
    }
    
    /// Perform a full compatibility check including health.
    /// - Parameters:
    ///   - port: The port the proxy is running on
    ///   - host: The host (defaults to 127.0.0.1)
    /// - Returns: Compatibility check result (checks health first, then compatibility)
    func fullCheck(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> CompatibilityCheckResult {
        // First check if proxy is healthy
        guard await isHealthy(port: port, host: host, managementKey: managementKey) else {
            return .proxyNotRunning
        }
        
        // Then check compatibility (which is now just verifying it responds)
        return await checkCompatibility(port: port, host: host, managementKey: managementKey)
    }
    
    // MARK: - Private Helpers
    
    private func makeManagementRequest(baseURL: String, managementKey: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)/v0/management/debug") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.addValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checkManagementEndpoint(baseURL: String, managementKey: String) async throws -> Bool {
        guard let request = makeManagementRequest(baseURL: baseURL, managementKey: managementKey) else {
            throw APIError.invalidURL
        }
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        return 200...299 ~= httpResponse.statusCode
    }
}

// MARK: - Convenience Extensions

extension CompatibilityCheckResult {
    /// Check if the result indicates the proxy should be usable.
    var shouldProceed: Bool {
        switch self {
        case .compatible:
            return true
        case .proxyNotResponding, .proxyNotRunning, .connectionError:
            return false
        }
    }
}
