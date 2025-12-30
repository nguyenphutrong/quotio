//
//  CKProviderChip.swift
//  CKota
//
//  Provider chip displaying provider icon, name, and optional count badge.
//  Uses consistent styling with CCS design system.
//

import SwiftUI

// MARK: - CKProviderChip

/// Chip displaying AI provider with optional count badge.
struct CKProviderChip: View {
    let provider: AIProvider
    var count: Int = 1
    var isSelected: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: .ckXS) {
                ProviderIcon(provider: provider, size: 16)

                Text(provider.displayName)
                    .font(.ckCallout)

                if count > 1 {
                    Text("\(count)")
                        .font(.ckCaption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(provider.color.opacity(0.3))
                        )
                }
            }
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckSM)
            .background(
                Capsule()
                    .fill(isSelected ? provider.color.opacity(0.2) : provider.color.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? provider.color : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(provider.color)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName), \(count) account\(count == 1 ? "" : "s")")
        .ckCursorPointer()
    }
}

// MARK: - Disconnected Provider Chip

/// Chip for adding a new provider (plus icon, secondary styling).
struct CKAddProviderChip: View {
    let provider: AIProvider
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            Label(provider.displayName, systemImage: "plus.circle")
                .font(.ckCallout)
                .padding(.horizontal, .ckMD)
                .padding(.vertical, .ckSM)
                .background(
                    Capsule()
                        .fill(Color.ckMuted)
                )
                .foregroundStyle(Color.ckMutedForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(provider.displayName)")
        .ckCursorPointer()
    }
}

// MARK: - Preview

#Preview("CKProviderChip") {
    VStack(alignment: .leading, spacing: .ckLG) {
        Text("Provider Chips")
            .font(.ckTitle)

        VStack(alignment: .leading, spacing: .ckMD) {
            Text("Connected Providers")
                .font(.ckHeadline)

            FlowLayout(spacing: 8) {
                CKProviderChip(provider: .claude, count: 3)
                CKProviderChip(provider: .antigravity, count: 5, isSelected: true)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: .ckMD) {
            Text("Add Providers")
                .font(.ckHeadline)

            FlowLayout(spacing: 8) {
                CKAddProviderChip(provider: .claude)
                CKAddProviderChip(provider: .antigravity)
            }
        }
    }
    .padding()
    .background(Color.ckBackground)
}
