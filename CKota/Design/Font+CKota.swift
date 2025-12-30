import SwiftUI

// MARK: - CKota Typography

extension Font {
    /// 24px Semibold - Page titles
    static let ckLargeTitle = Font.system(size: 24, weight: .semibold)

    /// 18px Semibold - Section headers
    static let ckTitle = Font.system(size: 18, weight: .semibold)

    /// 14px Semibold - Card titles
    static let ckHeadline = Font.system(size: 14, weight: .semibold)

    /// 13px Regular - Primary content
    static let ckBody = Font.system(size: 13, weight: .regular)

    /// 13px Medium - Emphasized body
    static let ckBodyMedium = Font.system(size: 13, weight: .medium)

    /// 12px Regular - Secondary content
    static let ckCallout = Font.system(size: 12, weight: .regular)

    /// 11px Regular - Timestamps, descriptions
    static let ckFootnote = Font.system(size: 11, weight: .regular)

    /// 10px Medium - Section labels, uppercase
    static let ckCaption = Font.system(size: 10, weight: .medium)

    /// 12px Mono - API endpoints, code
    static let ckMonoBody = Font.system(size: 12, weight: .regular, design: .monospaced)

    /// 10px Mono - Version badges
    static let ckMonoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
}

// MARK: - Text Style Modifiers

extension View {
    /// Section label style (10px, uppercase, tracking)
    func ckSectionLabel() -> some View {
        font(.ckCaption)
            .foregroundStyle(Color.ckMutedForeground)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    /// Muted text style
    func ckMuted() -> some View {
        font(.ckCallout)
            .foregroundStyle(Color.ckMutedForeground)
    }
}
