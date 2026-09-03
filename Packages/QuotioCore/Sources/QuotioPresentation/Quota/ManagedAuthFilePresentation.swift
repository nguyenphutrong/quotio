import QuotioDomain
import SwiftUI

public extension ManagedAuthFile {
    var statusColor: Color {
        switch status {
        case "ready": disabled ? .gray : .green
        case "cooling": .orange
        case "error": .red
        default: .gray
        }
    }
}
