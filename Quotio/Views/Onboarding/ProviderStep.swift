//
//  ProviderStep.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import SwiftUI

struct ProviderStep: View {
    @Bindable var viewModel: OnboardingViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            headerSection
            
            providersGrid
                .frame(maxWidth: 520)
            
            hintSection
            
            Spacer()
            
            navigationButtons
        }
        .padding(40)
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("onboarding.providers.title".localized())
                .font(.title2)
                .fontWeight(.bold)
            
            Text("onboarding.providers.subtitle".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var providersGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            ForEach(featuredProviders) { provider in
                ProviderPreviewCard(provider: provider)
            }
        }
    }
    
    private var featuredProviders: [AIProvider] {
        [.gemini, .claude, .codex, .copilot, .antigravity, .qwen]
    }
    
    private var hintSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            
            Text("onboarding.providers.hint".localized())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

struct ProviderPreviewCard: View {
    let provider: AIProvider
    
    var body: some View {
        VStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 40)
            
            Text(provider.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ProviderStep(viewModel: OnboardingViewModel())
}
