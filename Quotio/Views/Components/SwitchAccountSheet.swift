//
//  SwitchAccountSheet.swift
//  Quotio
//
//  Confirmation sheet for switching Antigravity accounts in the IDE.
//  Shows progress states and handles success/failure.
//

import SwiftUI

/// Sheet for confirming and executing Antigravity account switch
struct SwitchAccountSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var settings = MenuBarSettingsManager.shared
    
    let accountEmail: String
    let onDismiss: () -> Void
    
    private var switchState: AccountSwitchState {
        viewModel.antigravitySwitcher.switchState
    }
    
    private var isIDERunning: Bool {
        viewModel.antigravitySwitcher.isIDERunning()
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            headerView
            
            Divider()
            
            // Content based on state
            contentView
            
            Divider()
            
            // Actions
            actionButtons
        }
        .padding(24)
        .frame(width: 380)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("antigravity.switch.title".localized())
                    .font(.headline)
                
                Text(accountEmail.masked(if: settings.hideSensitiveInfo))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var contentView: some View {
        switch switchState {
        case .idle, .confirming:
            confirmationContent
            
        case .switching(let progress):
            progressContent(progress: progress)
            
        case .success:
            successContent
            
        case .failed(let message):
            failureContent(message: message)
        }
    }
    
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("antigravity.switch.confirm".localized())
                .font(.body)
            
            if isIDERunning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("antigravity.switch.ideRunning".localized())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func progressContent(progress: AccountSwitchState.SwitchProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text(progressText(for: progress))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // Progress steps
            VStack(alignment: .leading, spacing: 8) {
                progressStep(.closingIDE, current: progress)
                progressStep(.creatingBackup, current: progress)
                progressStep(.injectingToken, current: progress)
                progressStep(.restartingIDE, current: progress)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
    
    private func progressStep(_ step: AccountSwitchState.SwitchProgress, current: AccountSwitchState.SwitchProgress) -> some View {
        let isComplete = stepOrder(step) < stepOrder(current)
        let isCurrent = step == current
        
        return HStack(spacing: 10) {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isCurrent {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            }
            
            Text(progressText(for: step))
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }
    
    private func stepOrder(_ step: AccountSwitchState.SwitchProgress) -> Int {
        switch step {
        case .closingIDE: return 0
        case .creatingBackup: return 1
        case .injectingToken: return 2
        case .restartingIDE: return 3
        }
    }
    
    private func progressText(for progress: AccountSwitchState.SwitchProgress) -> String {
        switch progress {
        case .closingIDE: return "antigravity.switch.progress.closing".localized()
        case .creatingBackup: return "antigravity.switch.progress.backup".localized()
        case .injectingToken: return "antigravity.switch.progress.injecting".localized()
        case .restartingIDE: return "antigravity.switch.progress.restarting".localized()
        }
    }
    
    private var successContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            
            Text("antigravity.switch.success".localized())
                .font(.headline)
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    private func failureContent(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            
            Text("antigravity.switch.failed".localized())
                .font(.headline)
                .foregroundStyle(.red)
            
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    // MARK: - Actions
    
    @ViewBuilder
    private var actionButtons: some View {
        switch switchState {
        case .idle, .confirming:
            HStack {
                Button("action.cancel".localized()) {
                    viewModel.cancelAntigravitySwitch()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("antigravity.switch.title".localized()) {
                    Task {
                        await viewModel.switchAntigravityAccount(email: accountEmail)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            
        case .switching:
            // No buttons during switch
            EmptyView()
            
        case .success:
            Button("action.done".localized()) {
                viewModel.dismissAntigravitySwitchResult()
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            
        case .failed:
            HStack {
                Button("action.cancel".localized()) {
                    viewModel.dismissAntigravitySwitchResult()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("action.retry".localized()) {
                    Task {
                        await viewModel.switchAntigravityAccount(email: accountEmail)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SwitchAccountSheet(
        accountEmail: "user@gmail.com",
        onDismiss: {}
    )
    .environment(QuotaViewModel())
}
