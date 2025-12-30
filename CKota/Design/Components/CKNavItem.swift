//
//  CKNavItem.swift
//  CKota
//
//  Sidebar navigation item with icon, title, and selection state.
//  Ensures 44pt minimum touch target for accessibility.
//

import SwiftUI

// MARK: - CKNavItem

/// Sidebar navigation item matching CCS design system.
struct CKNavItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    /// Optional badge count
    var badgeCount: Int?

    var body: some View {
        Button(action: action) {
            HStack(spacing: .ckMD) {
                Image(systemName: icon)
                    .font(.system(size: CKLayout.iconSizeSM, weight: .medium))
                    .frame(width: CKLayout.iconSize)

                Text(title)
                    .font(.ckBodyMedium)

                Spacer()

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.ckCaption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.2) : Color.ckAccent.opacity(0.15))
                        )
                        .foregroundStyle(isSelected ? .white : Color.ckAccent)
                }
            }
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckSM)
            .foregroundStyle(isSelected ? .white : Color.ckMutedForeground)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.ckAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .ckCursorPointer()
    }
}

// MARK: - CKNavSection

/// Section header for sidebar navigation groups
struct CKNavSection: View {
    let title: String

    var body: some View {
        Text(title)
            .ckSectionLabel()
            .padding(.horizontal, .ckMD)
            .padding(.top, .ckMD)
            .padding(.bottom, .ckXS)
    }
}

// MARK: - Preview

#Preview("CKNavItem") {
    struct PreviewWrapper: View {
        @State private var selection = "dashboard"

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                CKNavSection(title: "Overview")

                CKNavItem(
                    icon: "square.grid.2x2",
                    title: "Dashboard",
                    isSelected: selection == "dashboard",
                    action: { selection = "dashboard" }
                )

                CKNavItem(
                    icon: "chart.bar",
                    title: "Quota",
                    isSelected: selection == "quota",
                    action: { selection = "quota" },
                    badgeCount: 3
                )

                CKNavSection(title: "Settings")

                CKNavItem(
                    icon: "cpu",
                    title: "Providers",
                    isSelected: selection == "providers",
                    action: { selection = "providers" }
                )

                CKNavItem(
                    icon: "gearshape",
                    title: "Settings",
                    isSelected: selection == "settings",
                    action: { selection = "settings" }
                )
            }
            .padding(.ckSM)
            .frame(width: CKLayout.sidebarWidth)
            .background(Color.ckBackground)
        }
    }

    return PreviewWrapper()
}
