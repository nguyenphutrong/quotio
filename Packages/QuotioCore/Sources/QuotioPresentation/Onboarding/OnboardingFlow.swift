//
//  OnboardingFlow.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Multi-step onboarding wizard for new users
//

import QuotioApplication
import QuotioDomain
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case modeSelection = 1
    case providers = 2
    case completion = 3
    
    var title: String {
        switch self {
        case .welcome: return "onboarding.step.welcome".localizedStatic()
        case .modeSelection: return "onboarding.step.mode".localizedStatic()
        case .providers: return "onboarding.step.providers".localizedStatic()
        case .completion: return "onboarding.step.completion".localizedStatic()
        }
    }
}

@MainActor
@Observable
final class OnboardingViewModel {
    var currentStep: OnboardingStep = .welcome
    var selectedMode: OperatingMode = .monitor
    var direction: SlideDirection = .forward
    
    var visibleSteps: [OnboardingStep] {
        [.welcome, .modeSelection, .providers, .completion]
    }
    
    var currentStepIndex: Int {
        visibleSteps.firstIndex(of: currentStep) ?? 0
    }
    
    var totalSteps: Int {
        visibleSteps.count
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
    
}

enum SlideDirection {
    case forward
    case backward
}

public struct OnboardingFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = OnboardingViewModel()
    
    var onComplete: ((OperatingMode) -> Void)?

    public init(onComplete: ((OperatingMode) -> Void)? = nil) {
        self.onComplete = onComplete
    }
    
    public var body: some View {
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
        case .providers:
            ProviderStep(viewModel: viewModel)
        case .completion:
            CompletionStep(viewModel: viewModel) {
                onComplete?(viewModel.selectedMode)
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
