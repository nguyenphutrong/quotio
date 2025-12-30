import AppKit
import SwiftUI

// MARK: - CKota Spacing Scale

extension CGFloat {
    /// 2px - Micro gaps (icon-text tight)
    static let ckXXS: CGFloat = 2

    /// 4px - Icon-text gaps, inline spacing
    static let ckXS: CGFloat = 4

    /// 8px - Button padding, compact gaps
    static let ckSM: CGFloat = 8

    /// 12px - Card gaps, list item spacing
    static let ckMD: CGFloat = 12

    /// 16px - Card padding (small), section gaps
    static let ckLG: CGFloat = 16

    /// 20px - Card padding (standard)
    static let ckXL: CGFloat = 20

    /// 24px - Content area padding, large sections
    static let ckXXL: CGFloat = 24

    /// 32px - Major section separators
    static let ckXXXL: CGFloat = 32
}

// MARK: - Layout Constants

enum CKLayout {
    // MARK: Sidebar

    static let sidebarWidth: CGFloat = 224

    // MARK: Header/Footer

    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 40

    // MARK: Cards

    static let cardRadius: CGFloat = 12
    static let cardRadiusSM: CGFloat = 8
    static let cardPadding: CGFloat = 20
    static let cardPaddingSM: CGFloat = 16

    // MARK: Content

    static let contentPadding: CGFloat = 24
    static let cardGap: CGFloat = 12

    // MARK: Components

    static let progressBarHeight: CGFloat = 6
    static let progressBarHeightSM: CGFloat = 4
    static let statusDotSize: CGFloat = 6
    static let avatarSize: CGFloat = 36
    static let avatarSizeSM: CGFloat = 32
    static let iconSize: CGFloat = 16
    static let iconSizeSM: CGFloat = 14

    // MARK: Toggle

    static let toggleWidth: CGFloat = 36
    static let toggleHeight: CGFloat = 20
    static let toggleKnobSize: CGFloat = 14
}

// MARK: - Window Sizing

enum CKWindowSize {
    /// Main window default size
    static let defaultWidth: CGFloat = 800
    static let defaultHeight: CGFloat = 600

    /// Minimum constraints
    static let minWidth: CGFloat = 680
    static let minHeight: CGFloat = 480

    /// Menu bar popover
    static let popoverWidth: CGFloat = 320
    static let popoverMaxHeight: CGFloat = 480
}

// MARK: - CKFocusRing Modifier

/// Adds visible focus ring for keyboard navigation accessibility.
struct CKFocusRing: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(true)
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                    .stroke(Color.ckAccent, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
                    .padding(-2)
            )
    }
}

extension View {
    /// Adds focus ring styling for keyboard navigation.
    func ckFocusRing() -> some View {
        modifier(CKFocusRing())
    }
}

// MARK: - Touch Target Extension

extension View {
    /// Ensures minimum 44pt touch target for accessibility compliance.
    func ckTouchTarget(minSize: CGFloat = 44) -> some View {
        frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}

// MARK: - Card Hover State

/// Subtle scale effect on hover for interactive cards.
struct CKCardHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.01 : 1.0)
            .animation(.ckMicro, value: isHovered)
            .onHover { inside in
                isHovered = inside
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Adds subtle hover scaling to interactive cards.
    func ckCardHover() -> some View {
        modifier(CKCardHover())
    }
}

// MARK: - Pointing Hand Cursor

/// Adds pointing hand cursor on hover for clickable elements.
struct CKPointingHand: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    /// Adds pointing hand cursor on hover.
    func ckCursorPointer() -> some View {
        modifier(CKPointingHand())
    }
}

// MARK: - Nav Item Hover

/// Hover effect for sidebar/navigation items with background highlight and cursor.
struct CKNavItemHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.ckAccent.opacity(0.08) : Color.clear)
            )
            .padding(.vertical, -6)
            .padding(.horizontal, -8)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
            .onHover { inside in
                isHovered = inside
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Adds hover background highlight and cursor for nav items.
    func ckNavItemHover() -> some View {
        modifier(CKNavItemHover())
    }
}

// MARK: - Card Shadow

extension View {
    /// Adds consistent shadow for card depth.
    func ckCardShadow() -> some View {
        shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}
