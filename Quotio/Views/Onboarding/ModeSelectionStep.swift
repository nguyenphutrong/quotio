//
//  ModeSelectionStep.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import SwiftUI

struct ModeSelectionStep: View {
    @Bindable var viewModel: OnboardingViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            headerSection
            
            VStack(spacing: 12) {
                ForEach(OperatingMode.allCases) { mode in
                    OperatingModeCard(
                        mode: mode,
                        isSelected: viewModel.selectedMode == mode,
                        onSelect: { viewModel.selectedMode = mode }
                    )
                }
            }
            .frame(maxWidth: 520)
            
            Spacer()
            
            navigationButtons
        }
        .padding(40)
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("onboarding.mode.title".localized())
                .font(.title2)
                .fontWeight(.bold)
            
            Text("onboarding.mode.subtitle".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.goBack()
            } label: {
                Text("onboarding.button.back".localized())
                    .frame(width: 100)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            
            Button {
                viewModel.goNext()
            } label: {
                Text("onboarding.button.continue".localized())
                    .frame(width: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct OperatingModeCard: View {
    let mode: OperatingMode
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 14) {
            iconView
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(mode.displayName)
                        .font(.headline)
                    
                    if let badge = mode.badge {
                        Text(badge)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.15))
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }
                }
                
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
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
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }
    
    private var iconView: some View {
        Image(systemName: mode.icon)
            .font(.title2)
            .foregroundStyle(isSelected ? .white : mode.color)
            .frame(width: 44, height: 44)
            .background(isSelected ? mode.color : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(mode.color, lineWidth: isSelected ? 0 : 2)
            )
    }
    
    private var badgeColor: Color {
        switch mode {
        case .monitor: return .green
        case .remoteProxy: return .purple
        default: return .gray
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

#Preview {
    ModeSelectionStep(viewModel: OnboardingViewModel())
}
