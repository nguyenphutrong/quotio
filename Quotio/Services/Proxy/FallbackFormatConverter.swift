//
//  FallbackFormatConverter.swift
//  Quotio - Fallback Error Detection
//
//  Simplified: Only handles error detection for triggering fallback.
//  Format conversion removed - fallback only works between same model types.
//

import Foundation

// MARK: - Fallback Error Detection

/// Handles error detection for cross-provider fallback
/// Format conversion is no longer needed since fallback only works between same model types
nonisolated struct FallbackFormatConverter {

    /// Check if a model name is a Claude model
    static func isClaudeModel(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        return ["claude", "opus", "haiku", "sonnet"].contains { lower.contains($0) }
    }

    /// Check if response indicates an error that should trigger fallback
    /// Includes quota exhaustion, rate limits, format errors, and server errors
    static func shouldTriggerFallback(responseData: Data) -> Bool {
        guard let responseString = String(data: responseData.prefix(4096), encoding: .utf8) else {
            return false
        }

        // Check HTTP status code
        if let firstLine = responseString.components(separatedBy: "\r\n").first {
            let parts = firstLine.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                switch code {
                case 429, 503, 500, 400, 401, 403, 422:
                    return true
                case 200..<300:
                    return false
                default:
                    break
                }
            }
        }

        // Check error patterns in response body
        let lowercased = responseString.lowercased()
        let errorPatterns = [
            "quota exceeded", "rate limit", "limit reached", "no available account",
            "insufficient_quota", "resource_exhausted", "overloaded", "capacity",
            "too many requests", "throttl", "invalid_request", "bad request",
            "authentication", "unauthorized", "invalid api key",
            "access denied", "model not found", "model unavailable", "does not exist"
        ]

        for pattern in errorPatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }

        return false
    }
}
