import Foundation
import QuotioDomain
import SwiftUI

public extension ManagedAuthFile {
    var humanReadableStatus: String? {
        guard let statusMessage, !statusMessage.isEmpty else { return nil }
        let trimmed = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return statusMessage
    }

    var statusColor: Color {
        switch status {
        case "ready": disabled ? .gray : .green
        case "cooling": .orange
        case "error": .red
        default: .gray
        }
    }
}
