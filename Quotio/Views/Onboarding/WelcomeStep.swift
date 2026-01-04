//
//  WelcomeStep.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import SwiftUI

struct WelcomeStep: View {
    @Bindable var viewModel: OnboardingViewModel
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            }
            
            VStack(spacing: 12) {
                Text("onboarding.welcome.title".localized())
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("onboarding.welcome.subtitle".localized())
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            Spacer()
            
            Button {
                viewModel.goNext()
            } label: {
                Text("onboarding.button.getStarted".localized())
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}

#Preview {
    WelcomeStep(viewModel: OnboardingViewModel())
}
