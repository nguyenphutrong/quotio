//
//  OnboardingFlow.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Multi-step onboarding wizard for new users
//

import QuotioApplication
import QuotioDomain
import SwiftUI

public struct OnboardingFlow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(QuotaScreenModel.self) private var quota
    @State private var viewModel = OnboardingViewModel()

    var onComplete: ((OperatingMode) -> Void)?

    public init(onComplete: ((OperatingMode) -> Void)? = nil) {
        self.onComplete = onComplete
    }

    private var overview: OnboardingProviderOverview {
        OnboardingProviderOverview(
            providers: controller.providers,
            accounts: accounts.accounts,
            permissions: accounts.nativeSourcePermissions,
            quota: quota.state,
            tracking: controller.trackingPreferences,
            hasStorageProblem: accounts.storageProblem != nil
        )
    }

    public var body: some View {
        let overview = overview
        VStack(spacing: 0) {
            if viewModel.currentStep != .welcome {
                header(needsAccess: overview.needsAccess)
            }

            // minHeight 0 lets the step accept whatever height remains, so long content
            // (or a longer translation) can never push the footer past the sheet edge.
            stepContent(overview)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .id(viewModel.currentStep)
                .transition(slideTransition)

            Divider()

            footer(needsAccess: overview.needsAccess)
        }
        .frame(width: 580, height: 520)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3), value: viewModel.currentStep)
    }

    @ViewBuilder
    private func stepContent(_ overview: OnboardingProviderOverview) -> some View {
        switch viewModel.currentStep {
        case .welcome:
            WelcomeStep()
        case .connect:
            ProviderStep(overview: overview)
        case .access:
            AccessStep(overview: overview)
        case .finish:
            CompletionStep(overview: overview)
        }
    }

    private func header(needsAccess: Bool) -> some View {
        VStack(spacing: 12) {
            OnboardingProgressView(
                steps: viewModel.progressSteps(needsAccess: needsAccess),
                current: viewModel.currentStep
            )

            VStack(spacing: 4) {
                Text(headerTitleKey.localized())
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(headerSubtitleKey.localized())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
    }

    private var headerTitleKey: String {
        switch viewModel.currentStep {
        case .welcome: "onboarding.welcome.title"
        case .connect: "onboarding.providers.title"
        case .access: "onboarding.access.title"
        case .finish: "onboarding.completion.title"
        }
    }

    private var headerSubtitleKey: String {
        switch viewModel.currentStep {
        case .welcome: "onboarding.welcome.subtitle"
        case .connect: "onboarding.providers.subtitle"
        case .access: "onboarding.access.subtitle"
        case .finish: "onboarding.completion.subtitle"
        }
    }

    private func footer(needsAccess: Bool) -> some View {
        HStack(spacing: 12) {
            if viewModel.canGoBack(needsAccess: needsAccess) {
                Button("onboarding.button.back".localized()) {
                    viewModel.goBack(needsAccess: needsAccess)
                }
                .keyboardShortcut("[", modifiers: .command)
            }

            Spacer()

            Button(primaryTitleKey.localized()) {
                if viewModel.currentStep == .finish {
                    onComplete?(.monitor)
                    dismiss()
                } else {
                    viewModel.goNext(needsAccess: needsAccess)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var primaryTitleKey: String {
        switch viewModel.currentStep {
        case .welcome: "onboarding.button.getStarted"
        case .connect, .access: "onboarding.button.continue"
        case .finish: "onboarding.button.startMonitoring"
        }
    }

    private var slideTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
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
}

private struct OnboardingProgressView: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Capsule()
                        .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 28, height: 2)
                }
                HStack(spacing: 6) {
                    marker(index: index)
                    Text(step.titleKey.localized())
                        .font(.callout.weight(index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index == currentIndex ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: "onboarding.progress.accessibility".localized(),
            currentIndex + 1,
            steps.count,
            current.titleKey.localized()
        ))
    }

    @ViewBuilder
    private func marker(index: Int) -> some View {
        ZStack {
            if index < currentIndex {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            } else if index == currentIndex {
                Circle().fill(Color.accentColor)
                Text(String(index + 1))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                Text(String(index + 1))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}
