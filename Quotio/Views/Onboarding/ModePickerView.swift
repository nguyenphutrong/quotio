//
//  ModePickerView.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Onboarding view for selecting app mode (Full vs Quota-Only)
//

import SwiftUI

struct ModePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: AppMode = .full
    private let modeManager = AppModeManager.shared
    
    var onComplete: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerSection
            
            // Mode Options
            VStack(spacing: 12) {
                ModeOptionCard(
                    mode: .full,
                    isSelected: selectedMode == .full
                ) { selectedMode = .full }
                
                ModeOptionCard(
                    mode: .quotaOnly,
                    isSelected: selectedMode == .quotaOnly
                ) { selectedMode = .quotaOnly }
            }
            .frame(maxWidth: 520)
            
            Spacer()
            
            // Continue Button
            VStack(spacing: 12) {
                Button {
                    modeManager.setMode(selectedMode)
                    modeManager.setOnboardingCompleted(true)
                    onComplete?()
                    dismiss()
                } label: {
                    Text("Get Started")
                        .frame(width: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Text("You can change this anytime in Settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(width: 600, height: 520)
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            
            Text("Welcome to Quotio")
                .font(.title)
                .fontWeight(.bold)
            
            Text("How would you like to use Quotio?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mode Option Card

struct ModeOptionCard: View {
    let mode: AppMode
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        cardContent
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .focusable(false)
    }
    
    private var cardContent: some View {
        HStack(spacing: 14) {
            // Icon
            iconView
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.4))
        }
        .padding(16)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
    
    private var iconView: some View {
        Image(systemName: mode.icon)
            .font(.title2)
            .foregroundStyle(isSelected ? .white : modeColor)
            .frame(width: 44, height: 44)
            .background(isSelected ? modeColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(modeColor, lineWidth: isSelected ? 0 : 2)
            )
    }
    
    private var modeColor: Color {
        switch mode {
        case .full: return .blue
        case .quotaOnly: return .green
        }
    }
    
    private var borderColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered {
            return Color.secondary.opacity(0.5)
        } else {
            return Color.secondary.opacity(0.2)
        }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            Color.accentColor.opacity(0.08)
        } else if isHovered {
            Color.secondary.opacity(0.05)
        } else {
            Color.clear
        }
    }
}

// MARK: - Preview

#Preview {
    ModePickerView()
}
