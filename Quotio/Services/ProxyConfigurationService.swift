//
//  ProxyConfigurationService.swift
//  Quotio
//
//  Created by Antigravity on 2026/01/11.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProxyConfigurationService {
    static let shared = ProxyConfigurationService()

    /// Current upstream proxy URL (validated and sanitized)
    var upstreamProxyURL: String? {
        guard let savedURL = UserDefaults.standard.string(forKey: "proxyURL"),
              !savedURL.isEmpty else {
            return nil
        }

        let sanitized = ProxyURLValidator.sanitize(savedURL)
        guard ProxyURLValidator.validate(sanitized) == .valid else {
            return nil
        }

        return sanitized
    }

    /// Create a URLSessionConfiguration with proxy settings applied
    func createProxiedConfiguration(timeout: TimeInterval = 15) -> URLSessionConfiguration {
        Self.createProxiedConfigurationStatic(timeout: timeout)
    }
    
    /// Static nonisolated method to create proxied configuration
    /// Can be called from any actor context
    nonisolated static func createProxiedConfigurationStatic(timeout: TimeInterval = 15) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout

        // Read proxy URL from UserDefaults directly (thread-safe)
        if let proxyURLString = UserDefaults.standard.string(forKey: "proxyURL"),
           !proxyURLString.isEmpty {
            let sanitized = ProxyURLValidator.sanitize(proxyURLString)
            if ProxyURLValidator.validate(sanitized) == .valid,
               let url = URL(string: sanitized) {
                config.connectionProxyDictionary = proxyDictionary(from: url)
            }
        }

        return config
    }

    nonisolated static private func proxyDictionary(from url: URL) -> [AnyHashable: Any]? {
        guard let host = url.host else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 8080)

        var dict: [AnyHashable: Any] = [:]

        switch url.scheme?.lowercased() {
        case "http":
            dict[kCFNetworkProxiesHTTPEnable] = true
            dict[kCFNetworkProxiesHTTPProxy] = host
            dict[kCFNetworkProxiesHTTPPort] = port

            // Also enable for HTTPS using the same proxy
            dict[kCFNetworkProxiesHTTPSEnable] = true
            dict[kCFNetworkProxiesHTTPSProxy] = host
            dict[kCFNetworkProxiesHTTPSPort] = port

        case "https":
            dict[kCFNetworkProxiesHTTPSEnable] = true
            dict[kCFNetworkProxiesHTTPSProxy] = host
            dict[kCFNetworkProxiesHTTPSPort] = port

        case "socks5":
            dict[kCFStreamPropertySOCKSProxyHost] = host
            dict[kCFStreamPropertySOCKSProxyPort] = port
            dict[kCFStreamPropertySOCKSVersion] = kCFStreamSocketSOCKSVersion5

            // Add authentication if present
            if let user = url.user {
                dict[kCFStreamPropertySOCKSUser] = user
            }
            if let password = url.password {
                dict[kCFStreamPropertySOCKSPassword] = password
            }

        default:
            return nil
        }

        return dict
    }
}
