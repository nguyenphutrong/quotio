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

    /// Determine the reason a response should trigger fallback.
    static func fallbackReason(responseData: Data) -> FallbackTriggerReason? {
        guard let responseString = String(data: responseData.prefix(4096), encoding: .utf8) else {
            return nil
        }

        // Check HTTP status code
        if let firstLine = responseString.components(separatedBy: "\r\n").first {
            let parts = firstLine.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                switch code {
                case 429, 503, 500, 400, 401, 403, 422:
                    return .httpStatus(code)
                case 200..<300:
                    return nil
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
                return .pattern(pattern)
            }
        }

        return nil
    }

    /// Check if response indicates an error that should trigger fallback
    /// Includes quota exhaustion, rate limits, format errors, and server errors
    static func shouldTriggerFallback(responseData: Data) -> Bool {
        fallbackReason(responseData: responseData) != nil
    }

    static func isThinkingSignatureError(responseData: Data) -> Bool {
        guard let responseString = String(data: responseData.prefix(4096), encoding: .utf8) else {
            return false
        }

        let errorMessage = extractErrorMessage(from: responseString)
        let message = errorMessage.lowercased()

        let isSignatureError = message.contains("signature") && message.contains("thinking")
        let isMustMatchError = message.contains("thinking") &&
            (message.contains("must match") || message.contains("parameters during the original request"))

        return isSignatureError || isMustMatchError
    }

    private static func extractErrorMessage(from response: String) -> String {
        guard let bodyStart = response.range(of: "\r\n\r\n") else {
            return response
        }

        let body = String(response[bodyStart.upperBound...])

        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return body
        }

        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }
            if let upstreamError = error["upstream_error"] as? [String: Any],
               let innerError = upstreamError["error"] as? [String: Any],
               let message = innerError["message"] as? String {
                return message
            }
        }

        return body
    }
}
