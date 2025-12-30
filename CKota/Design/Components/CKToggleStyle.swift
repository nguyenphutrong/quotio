//
//  CKToggleStyle.swift
//  CKota
//
//  Custom toggle style with CKota design tokens.
//  Ensures 44pt minimum touch target for accessibility.
//

import SwiftUI

// MARK: - CKToggleStyle

/// Custom toggle style matching CCS design system.
struct CKToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label

            Spacer()

            // Toggle track
            RoundedRectangle(cornerRadius: CKLayout.toggleHeight / 2)
                .fill(configuration.isOn ? Color.ckAccent : Color.ckMuted)
                .frame(width: CKLayout.toggleWidth, height: CKLayout.toggleHeight)
                .overlay(
                    // Toggle knob
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                        .frame(width: CKLayout.toggleKnobSize, height: CKLayout.toggleKnobSize)
                        .offset(x: configuration.isOn ? 7 : -7)
                )
                .animation(.ckStandard, value: configuration.isOn)
                .onTapGesture {
                    withAnimation(.ckStandard) {
                        configuration.isOn.toggle()
                    }
                }
                .ckCursorPointer()
        }
        .frame(minHeight: 44) // Accessibility touch target
        .contentShape(Rectangle())
    }
}

// MARK: - Extension

extension ToggleStyle where Self == CKToggleStyle {
    /// CKota toggle style
    static var ckToggle: CKToggleStyle { CKToggleStyle() }
}

// MARK: - Preview

#Preview("CKToggleStyle") {
    struct PreviewWrapper: View {
        @State private var isOn1 = true
        @State private var isOn2 = false
        @State private var isOn3 = true

        var body: some View {
            VStack(alignment: .leading, spacing: .ckLG) {
                Text("Toggle Style")
                    .font(.ckTitle)

                VStack(spacing: 0) {
                    Toggle("Auto-start proxy", isOn: $isOn1)
                        .toggleStyle(.ckToggle)

                    Divider()

                    Toggle("Show notifications", isOn: $isOn2)
                        .toggleStyle(.ckToggle)

                    Divider()

                    Toggle("Enable dark mode", isOn: $isOn3)
                        .toggleStyle(.ckToggle)
                }
                .ckCard()
            }
            .padding()
            .background(Color.ckBackground)
        }
    }

    return PreviewWrapper()
}
