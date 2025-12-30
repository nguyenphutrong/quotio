//
//  CKSegmentedTabs.swift
//  CKota
//
//  Segmented tab bar for switching between views.
//  Supports any Hashable type with CustomStringConvertible.
//

import SwiftUI

// MARK: - CKSegmentedTabs

/// Segmented tab control matching CCS design system.
/// Active tab has white/card background, inactive tabs have muted background.
struct CKSegmentedTabs<T: Hashable>: View {
    let tabs: [T]
    @Binding var selection: T

    /// Function to get display label for tab
    var label: (T) -> String

    init(tabs: [T], selection: Binding<T>, label: @escaping (T) -> String) {
        self.tabs = tabs
        self._selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.ckStandard) {
                        selection = tab
                    }
                } label: {
                    Text(label(tab))
                        .font(.ckBodyMedium)
                        .padding(.horizontal, .ckMD)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selection == tab ? Color.ckCard : Color.clear)
                                .shadow(
                                    color: selection == tab ? .black.opacity(0.05) : .clear,
                                    radius: 1,
                                    y: 1
                                )
                        )
                        .foregroundStyle(selection == tab ? Color.ckForeground : Color.ckMutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .ckCursorPointer()
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.ckMuted)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab selection")
    }
}

// MARK: - Convenience for CustomStringConvertible

extension CKSegmentedTabs where T: CustomStringConvertible {
    init(tabs: [T], selection: Binding<T>) {
        self.tabs = tabs
        self._selection = selection
        self.label = { $0.description }
    }
}

// MARK: - Preview

#Preview("CKSegmentedTabs") {
    struct PreviewWrapper: View {
        enum SettingsTab: String, CaseIterable, CustomStringConvertible {
            case general = "General"
            case proxy = "Proxy"
            case notifications = "Notifications"
            case advanced = "Advanced"

            var description: String { rawValue }
        }

        @State private var selectedTab: SettingsTab = .general
        @State private var selectedIndex = 0

        var body: some View {
            VStack(alignment: .leading, spacing: .ckLG) {
                Text("Segmented Tabs")
                    .font(.ckTitle)

                VStack(alignment: .leading, spacing: .ckMD) {
                    Text("Enum-based")
                        .font(.ckHeadline)

                    CKSegmentedTabs(
                        tabs: SettingsTab.allCases,
                        selection: $selectedTab
                    )

                    Text("Selected: \(selectedTab.rawValue)")
                        .font(.ckCallout)
                        .foregroundStyle(Color.ckMutedForeground)
                }

                Divider()

                VStack(alignment: .leading, spacing: .ckMD) {
                    Text("Custom Labels")
                        .font(.ckHeadline)

                    CKSegmentedTabs(
                        tabs: [0, 1, 2],
                        selection: $selectedIndex,
                        label: { "Tab \($0 + 1)" }
                    )

                    Text("Selected index: \(selectedIndex)")
                        .font(.ckCallout)
                        .foregroundStyle(Color.ckMutedForeground)
                }
            }
            .padding()
            .background(Color.ckBackground)
        }
    }

    return PreviewWrapper()
}
