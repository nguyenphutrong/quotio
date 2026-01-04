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
    
    let provider: AIProvider
    let accountKey: String
    let accountEmail: String
    let onDismiss: () -> Void
    
    private var isWarmupEnabled: Bool {
        viewModel.isWarmupEnabled(for: provider, accountKey: accountKey)
    }
    
    private var displayEmail: String {
        accountEmail.masked(if: settings.hideSensitiveInfo)
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
                Picker("", selection: $warmupSettings.warmupScheduleMode) {
                    ForEach(WarmupScheduleMode.allCases) { mode in
                        Text(mode.localizationKey.localized())
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            
            if warmupSettings.warmupScheduleMode == .interval {
                HStack {
                    Text("warmup.interval.label".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $warmupSettings.warmupCadence) {
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
                        selection: $warmupSettings.warmupDailyTime,
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
                onDismiss()
            }
            .disabled(!isWarmupEnabled)
            
            Button("warmup.enable".localized()) {
                viewModel.setWarmupEnabled(true, provider: provider, accountKey: accountKey)
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
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
        let saved = warmupSettings.selectedModels(provider: provider, accountKey: accountKey)
        if saved.isEmpty {
            let defaults = viewModel.defaultWarmupSelection(from: models)
            selectedModels = Set(defaults)
            warmupSettings.setSelectedModels(defaults, provider: provider, accountKey: accountKey)
        } else {
            selectedModels = Set(saved)
        }
        isLoadingModels = false
    }
}
