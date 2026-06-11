//
//  OnboardingFlow.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Multi-step onboarding wizard for new users
//

import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case modeSelection = 1
    case remoteSetup = 2
    case providers = 3
    case completion = 4
    
    var title: String {
        switch self {
        case .welcome: return "onboarding.step.welcome".localizedStatic()
        case .modeSelection: return "onboarding.step.mode".localizedStatic()
        case .remoteSetup: return "onboarding.step.remote".localizedStatic()
        case .providers: return "onboarding.step.providers".localizedStatic()
        case .completion: return "onboarding.step.completion".localizedStatic()
        }
    }
}

@MainActor
@Observable
final class OnboardingViewModel {
    var currentStep: OnboardingStep = .welcome
    var selectedMode: OperatingMode = .localProxy
    var remoteEndpoint: String = ""
    var remoteManagementKey: String = ""
    var direction: SlideDirection = .forward
    @ObservationIgnored private let modeManager = OperatingModeManager.shared
    @ObservationIgnored private let proxyManager = CLIProxyManager.shared
    
    var visibleSteps: [OnboardingStep] {
        if selectedMode == .remoteProxy {
            return [.welcome, .modeSelection, .remoteSetup, .providers, .completion]
        } else {
            return [.welcome, .modeSelection, .providers, .completion]
        }
    }
    
    var currentStepIndex: Int {
        visibleSteps.firstIndex(of: currentStep) ?? 0
    }
    
    var totalSteps: Int {
        visibleSteps.count
    }
    
    var canGoBack: Bool {
        currentStepIndex > 0
    }
    
    var canGoNext: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .modeSelection:
            return true
        case .remoteSetup:
            return isRemoteConfigValid
        case .providers:
            return true
        case .completion:
            return true
        }
    }
    
    var isRemoteConfigValid: Bool {
        let validation = RemoteURLValidator.validate(remoteEndpoint)
        return validation.isValid && !remoteManagementKey.isEmpty
    }

    var localModeNotice: (title: String, message: String)? {
        if let devPath = proxyManager.cpaPlusPlusDevBinaryPath {
            return (
                "onboarding.local.useExistingGateway".localized(),
                String(format: "onboarding.local.devBinaryMessage".localized(), devPath)
            )
        }

        if let legacyPrompt = proxyManager.legacyMigrationPrompt {
            return ("onboarding.local.useBundledGateway".localized(), legacyPrompt)
        }

        if !proxyManager.isBinaryInstalled {
            return (
                "onboarding.local.useBundledGateway".localized(),
                "settings.gatewayMissingLong".localized()
            )
        }

        return nil
    }
    
    func goNext() {
        direction = .forward
        let currentIndex = currentStepIndex
        if currentIndex < visibleSteps.count - 1 {
            currentStep = visibleSteps[currentIndex + 1]
        }
    }
    
    func goBack() {
        direction = .backward
        let currentIndex = currentStepIndex
        if currentIndex > 0 {
            currentStep = visibleSteps[currentIndex - 1]
        }
    }
    
    func completeOnboarding() {
        if selectedMode == .remoteProxy {
            let config = RemoteConnectionConfig(
                endpointURL: remoteEndpoint,
                displayName: "Remote Server"
            )
            modeManager.switchToRemote(config: config, managementKey: remoteManagementKey, fromOnboarding: true)
        } else {
            modeManager.completeOnboarding(mode: selectedMode)
        }
    }
}

enum SlideDirection {
    case forward
    case backward
}

struct OnboardingFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = OnboardingViewModel()
    
    var onComplete: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(viewModel.currentStep)
                .transition(slideTransition)
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentStep)
            
            progressIndicator
                .padding(.bottom, 24)
        }
        .frame(width: 640, height: 560)
    }
    
    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .welcome:
            WelcomeStep(viewModel: viewModel)
        case .modeSelection:
            ModeSelectionStep(viewModel: viewModel)
        case .remoteSetup:
            RemoteSetupStep(viewModel: viewModel)
        case .providers:
            ProviderStep(viewModel: viewModel)
        case .completion:
            CompletionStep(viewModel: viewModel) {
                viewModel.completeOnboarding()
                onComplete?()
                dismiss()
            }
        }
    }
    
    private var slideTransition: AnyTransition {
        switch viewModel.direction {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }
    
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<viewModel.totalSteps, id: \.self) { index in
                Circle()
                    .fill(index <= viewModel.currentStepIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.currentStepIndex)
            }
        }
    }
}

#Preview {
    OnboardingFlow()
}
