//
//  RemoteSetupStep.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import SwiftUI

struct RemoteSetupStep: View {
    @Bindable var viewModel: OnboardingViewModel
    @State private var showPassword = false
    
    private var urlValidation: RemoteURLValidationResult {
        RemoteURLValidator.validate(viewModel.remoteEndpoint)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            headerSection
            
            formSection
                .frame(maxWidth: 460)
            
            Spacer()
            
            navigationButtons
        }
        .padding(40)
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundStyle(.purple)
            
            Text("onboarding.remote.title".localized())
                .font(.title2)
                .fontWeight(.bold)
            
            Text("onboarding.remote.subtitle".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("onboarding.remote.endpoint".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                TextField("https://proxy.example.com:8317", text: $viewModel.remoteEndpoint)
                    .textFieldStyle(.roundedBorder)
                
                if !viewModel.remoteEndpoint.isEmpty, let errorKey = urlValidation.localizationKey {
                    Text(errorKey.localized())
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("onboarding.remote.managementKey".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack {
                    if showPassword {
                        TextField("onboarding.remote.managementKey.placeholder".localized(), text: $viewModel.remoteManagementKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("onboarding.remote.managementKey.placeholder".localized(), text: $viewModel.remoteManagementKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("onboarding.remote.managementKey.hint".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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
            .disabled(!viewModel.isRemoteConfigValid)
        }
    }
}

#Preview {
    RemoteSetupStep(viewModel: OnboardingViewModel())
}
