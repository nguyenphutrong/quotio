import SwiftUI

// MARK: - CKota Color Tokens

extension Color {
    // MARK: Semantic Colors (Light/Dark adaptive from Asset Catalog)

    static let ckBackground = Color("Background")
    static let ckForeground = Color("Foreground")
    static let ckCard = Color("Card")
    static let ckAccent = Color("Accent")
    static let ckAccentLight = Color("AccentLight")
    static let ckMuted = Color("Muted")
    static let ckMutedForeground = Color("MutedForeground")
    static let ckBorder = Color("Border")
    static let ckDestructive = Color("Destructive")

    // MARK: Semantic Status Colors (theme-independent)

    static let ckSuccess = Color(hex: "10B981")
    static let ckWarning = Color(hex: "F59E0B")

    // MARK: Provider Brand Colors

    static let ckClaude = Color(hex: "D97706")
    static let ckAntigravity = Color(hex: "4D7CFF")
    static let ckGemini = Color(hex: "4285F4")
    static let ckCodex = Color(hex: "10B981")
    static let ckCopilot = Color(hex: "6366F1")
    static let ckQwen = Color(hex: "6366F1")
    static let ckVertex = Color(hex: "EA4335")
    static let ckKiro = Color(hex: "FF6B35")
    static let ckCursor = Color(hex: "000000")

    // MARK: Hex Initializer

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: // RGB
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
