//
//  CompletionStep.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import SwiftUI

struct CompletionStep: View {
    @Bindable var viewModel: OnboardingViewModel
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            successIcon
            
            VStack(spacing: 12) {
                Text("onboarding.completion.title".localized())
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("onboarding.completion.subtitle".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            selectedModeCard
            
            Spacer()
            
            VStack(spacing: 12) {
                Button {
                    onComplete()
                } label: {
                    Text("onboarding.button.openDashboard".localized())
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Text("onboarding.completion.hint".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
    }
    
    private var successIcon: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 80, height: 80)
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
        }
    }
    
    private var selectedModeCard: some View {
        HStack(spacing: 14) {
            Image(systemName: viewModel.selectedMode.icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(viewModel.selectedMode.color)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedMode.displayName)
                    .font(.headline)
                
                Text(viewModel.selectedMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 400)
    }
}

#Preview {
    CompletionStep(viewModel: OnboardingViewModel()) {}
}
