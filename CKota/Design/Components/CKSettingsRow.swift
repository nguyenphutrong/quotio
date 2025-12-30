//
//  CKSettingsRow.swift
//  CKota
//
//  Settings row layout for settings screens.
//  Supports title, subtitle (for help text), and various trailing content.
//

import SwiftUI

// MARK: - CKSettingsRow

/// Settings row with title, optional subtitle, and trailing content.
struct CKSettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: .ckMD) {
            // Leading icon
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: CKLayout.iconSize))
                    .foregroundStyle(Color.ckMutedForeground)
                    .frame(width: 24)
            }

            // Title and subtitle
            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(title)
                    .font(.ckBody)
                    .foregroundStyle(Color.ckForeground)

                if let subtitle {
                    Text(subtitle)
                        .font(.ckFootnote)
                        .foregroundStyle(Color.ckMutedForeground)
                }
            }

            Spacer()

            // Trailing content
            trailing()
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Convenience Initializers

extension CKSettingsRow where Trailing == EmptyView {
    /// Row without trailing content
    init(title: String, subtitle: String? = nil, icon: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = { EmptyView() }
    }
}

extension CKSettingsRow where Trailing == Text {
    /// Row with text value trailing
    init(title: String, subtitle: String? = nil, icon: String? = nil, value: String) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = {
            Text(value)
                .font(.ckBody)
                .foregroundStyle(Color.ckMutedForeground)
        }
    }
}

// MARK: - CKSettingsSection

/// Section header for settings groups
struct CKSettingsSection: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: .ckXXS) {
            Text(title)
                .ckSectionLabel()

            if let subtitle {
                Text(subtitle)
                    .font(.ckFootnote)
                    .foregroundStyle(Color.ckMutedForeground)
            }
        }
    }
}

// MARK: - CKSettingsToggleRow

/// Settings row with toggle control
struct CKSettingsToggleRow: View {
    let title: String
    var subtitle: String?
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        CKSettingsRow(title: title, subtitle: subtitle, icon: icon) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.ckToggle)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(subtitle ?? "Double tap to toggle")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Preview

#Preview("CKSettingsRow") {
    struct PreviewWrapper: View {
        @State private var autoStart = true
        @State private var notifications = false
        @State private var selectedPort = "8000"

        var body: some View {
            VStack(alignment: .leading, spacing: .ckMD) {
                Text("Settings Rows")
                    .font(.ckTitle)

                VStack(spacing: 0) {
                    CKSettingsSection(title: "General")
                        .padding(.bottom, .ckSM)

                    CKSettingsToggleRow(
                        title: "Auto-start proxy",
                        subtitle: "Start the proxy when the app launches",
                        icon: "power",
                        isOn: $autoStart
                    )

                    Divider()

                    CKSettingsToggleRow(
                        title: "Show notifications",
                        icon: "bell",
                        isOn: $notifications
                    )

                    Divider()

                    CKSettingsRow(title: "Proxy port", icon: "network", value: selectedPort)
                }
                .ckCard()

                VStack(spacing: 0) {
                    CKSettingsSection(title: "About")
                        .padding(.bottom, .ckSM)

                    CKSettingsRow(title: "Version", value: "1.2.3")

                    Divider()

                    CKSettingsRow(title: "Build", value: "456")
                }
                .ckCard()
            }
            .padding()
            .background(Color.ckBackground)
        }
    }

    return PreviewWrapper()
}
