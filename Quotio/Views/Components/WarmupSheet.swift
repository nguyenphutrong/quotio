//
//  WarmupSheet.swift
//  Quotio
//

import SwiftUI

struct WarmupSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var settings = MenuBarSettingsManager.shared
    @State private var warmupSettings = WarmupSettingsManager.shared
    @State private var availableModels: [String] = []
    @State private var selectedModels: Set<String> = []
    @State private var isLoadingModels = false
    @State private var shouldAutoClose = false
    @State private var didSeeRunning = false
    
    let provider: AIProvider
    let accountKey: String
    let accountEmail: String
    let onDismiss: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    
    private var isWarmupEnabled: Bool {
        viewModel.isWarmupEnabled(for: provider, accountKey: accountKey)
    }
    
    private var displayEmail: String {
        accountEmail.masked(if: settings.hideSensitiveInfo)
    }

    private var warmupIsRunning: Bool {
        viewModel.warmupStatus(provider: provider, accountKey: accountKey).isRunning
    }

    private var scheduleModeBinding: Binding<WarmupScheduleMode> {
        Binding(
            get: { warmupSettings.warmupScheduleMode(provider: provider, accountKey: accountKey) },
            set: { warmupSettings.setWarmupScheduleMode($0, provider: provider, accountKey: accountKey) }
        )
    }

    private var cadenceBinding: Binding<WarmupCadence> {
        Binding(
            get: { warmupSettings.warmupCadence(provider: provider, accountKey: accountKey) },
            set: { warmupSettings.setWarmupCadence($0, provider: provider, accountKey: accountKey) }
        )
    }

    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: { warmupSettings.warmupDailyTime(provider: provider, accountKey: accountKey) },
            set: { warmupSettings.setWarmupDailyTime($0, provider: provider, accountKey: accountKey) }
        )
    }

    private var statusText: String {
        if !isWarmupEnabled {
            return "warmup.status.disabled".localized()
        }
        if selectedModels.isEmpty {
            return "warmup.status.noSelection".localized()
        }
        let status = viewModel.warmupStatus(provider: provider, accountKey: accountKey)
        if status.isRunning {
            return "warmup.status.running".localized()
        }
        if status.lastError != nil {
            return "warmup.status.failed".localized()
        }
        return "warmup.status.idle".localized()
    }

    private var lastRunText: String {
        let status = viewModel.warmupStatus(provider: provider, accountKey: accountKey)
        guard let lastRun = status.lastRun else {
            return "warmup.status.none".localized()
        }
        return Self.dateFormatter.string(from: lastRun)
    }

    private var nextRunText: String {
        guard let nextRun = viewModel.warmupNextRunDate(provider: provider, accountKey: accountKey) else {
            return "warmup.status.none".localized()
        }
        return Self.dateFormatter.string(from: nextRun)
    }

    private var progressText: String? {
        let status = viewModel.warmupStatus(provider: provider, accountKey: accountKey)
        guard status.isRunning, status.progressTotal > 0 else { return nil }
        return String(format: "warmup.status.progress".localized(), status.progressCompleted, status.progressTotal)
    }

    private var currentModelText: String? {
        let status = viewModel.warmupStatus(provider: provider, accountKey: accountKey)
        guard status.isRunning, let current = status.currentModel else { return nil }
        return String(format: "warmup.status.currentModel".localized(), current)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            headerView
            
            Divider()
            
            contentView
            
            Divider()
            
            actionButtons
        }
        .padding(24)
        .frame(width: 380)
        .task {
            await loadModelsIfNeeded()
        }
        .onChange(of: warmupIsRunning) { _, isRunning in
            if isRunning {
                didSeeRunning = true
            } else if shouldAutoClose, didSeeRunning {
                shouldAutoClose = false
                didSeeRunning = false
                onDismiss()
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("warmup.title".localized())
                    .font(.headline)
                
                Text(displayEmail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Content
    
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("warmup.time.title".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: scheduleModeBinding) {
                    ForEach(WarmupScheduleMode.allCases) { mode in
                        Text(mode.localizationKey.localized())
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            
            if warmupSettings.warmupScheduleMode(provider: provider, accountKey: accountKey) == .interval {
                HStack {
                    Text("warmup.interval.label".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: cadenceBinding) {
                        ForEach(WarmupCadence.allCases) { cadence in
                            Text(cadence.localizationKey.localized())
                                .tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            } else {
                HStack {
                    Text("warmup.daily.label".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker(
                        "",
                        selection: dailyTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("warmup.models.title".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                } else if availableModels.isEmpty {
                    Text("warmup.models.empty".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(availableModels, id: \.self) { model in
                                Toggle(model, isOn: binding(for: model))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 180)
                }
            }
            
            Text("warmup.description".localized())
                .font(.footnote)
                .foregroundStyle(.secondary)

            statusView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Actions
    
    private var actionButtons: some View {
        HStack {
            Button("action.cancel".localized()) {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Button("warmup.stop".localized()) {
                viewModel.setWarmupEnabled(false, provider: provider, accountKey: accountKey)
                shouldAutoClose = false
                didSeeRunning = false
                onDismiss()
            }
            .disabled(!isWarmupEnabled)
            
            Button("warmup.enable".localized()) {
                if isWarmupEnabled {
                    onDismiss()
                    return
                }
                shouldAutoClose = true
                didSeeRunning = warmupIsRunning
                viewModel.setWarmupEnabled(true, provider: provider, accountKey: accountKey)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("warmup.status.title".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if let progressText {
                Text(progressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let currentModelText {
                Text(currentModelText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("warmup.status.lastRun".localized())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lastRunText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("warmup.status.nextRun".localized())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(nextRunText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func binding(for model: String) -> Binding<Bool> {
        Binding(
            get: { selectedModels.contains(model) },
            set: { isOn in
                if isOn {
                    selectedModels.insert(model)
                } else {
                    selectedModels.remove(model)
                }
                let sorted = selectedModels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                warmupSettings.setSelectedModels(sorted, provider: provider, accountKey: accountKey)
            }
        )
    }
    
    private func loadModelsIfNeeded() async {
        guard provider == .antigravity else { return }
        guard availableModels.isEmpty else { return }
        isLoadingModels = true
        let models = await viewModel.warmupAvailableModels(provider: provider, accountKey: accountKey)
        availableModels = models
        if warmupSettings.hasStoredSelection(provider: provider, accountKey: accountKey) {
            let saved = warmupSettings.selectedModels(provider: provider, accountKey: accountKey)
            selectedModels = Set(saved)
        } else {
            selectedModels = []
        }
        isLoadingModels = false
    }
}
