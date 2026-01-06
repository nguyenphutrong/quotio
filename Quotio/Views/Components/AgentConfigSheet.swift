//
//  AgentConfigSheet.swift
//  Quotio - Agent configuration modal with automatic/manual modes
//

import SwiftUI

struct AgentConfigSheet: View {
    @Bindable var viewModel: AgentSetupViewModel
    let agent: CLIAgent
    
    @Environment(\.dismiss) private var dismiss
    @State private var previewConfig: AgentConfigResult?
    
    private var hasResult: Bool {
        viewModel.configResult != nil
    }
    
    private var isSuccess: Bool {
        viewModel.configResult?.success == true
    }
    
    private var isManualMode: Bool {
        viewModel.configurationMode == .manual
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    if hasResult {
                        resultView
                    } else {
                        configurationView
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            
            Divider()
            
            footerView
        }
        .frame(width: 720, height: 600)
        .onAppear {
            viewModel.resetSheetState()
            if isManualMode {
                generatePreview()
            }
        }
        .onChange(of: viewModel.configurationMode) { _, newMode in
            if newMode == .manual {
                generatePreview()
            } else {
                previewConfig = nil
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
    
    private func generatePreview() {
        Task {
            previewConfig = await viewModel.generatePreviewConfig()
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(agent.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: agent.systemIcon)
                    .font(.title3)
                    .foregroundStyle(agent.color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.configure".localized() + " " + agent.displayName)
                    .font(.headline)
                
                Text(agent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                viewModel.dismissConfiguration()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
    
    private var configurationView: some View {
        VStack(spacing: 16) {
            modeSelectionSection
            
            if agent == .claudeCode && !isManualMode {
                storageOptionSection
            }
            
            connectionInfoSection
            
            if agent == .claudeCode {
                modelSlotsSection
            }
            
            if agent == .geminiCLI {
                oauthToggleSection
            }
            
            if isManualMode {
                manualPreviewSection
            }
            
            testConnectionSection
        }
    }
    
    private var modeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.configMode".localized())
                .font(.subheadline)
                .fontWeight(.medium)
            
            HStack(spacing: 12) {
                ForEach(ConfigurationMode.allCases) { mode in
                    ModeButton(
                        mode: mode,
                        isSelected: viewModel.configurationMode == mode,
                        action: { viewModel.configurationMode = mode }
                    )
                }
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var storageOptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.storageOption".localized())
                .font(.subheadline)
                .fontWeight(.medium)
            
            HStack(spacing: 12) {
                ForEach(ConfigStorageOption.allCases) { option in
                    StorageOptionButton(
                        option: option,
                        isSelected: viewModel.configStorageOption == option,
                        action: { viewModel.configStorageOption = option }
                    )
                }
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var connectionInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.connectionInfo".localized())
                .font(.subheadline)
                .fontWeight(.medium)
            
            VStack(spacing: 6) {
                InfoRow(label: "agents.proxyURL".localized(), value: viewModel.currentConfiguration?.proxyURL ?? "")
                InfoRow(label: "agents.apiKey".localized(), value: maskedAPIKey, isMasked: true)
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var maskedAPIKey: String {
        guard let key = viewModel.currentConfiguration?.apiKey, key.count > 8 else {
            return "••••••••"
        }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }
    
    private var modelSlotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.modelSlots".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button {
                    Task { await viewModel.loadModels(forceRefresh: true) }
                } label: {
                    if viewModel.isFetchingModels {
                        SmallProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh models from proxy".localized())
                .disabled(viewModel.isFetchingModels)
            }
            
            VStack(spacing: 8) {
                ForEach(ModelSlot.allCases) { slot in
                    ModelSlotRow(
                        slot: slot,
                        selectedModel: viewModel.currentConfiguration?.modelSlots[slot] ?? "",
                        availableModels: viewModel.availableModels,
                        onModelChange: { model in
                            viewModel.updateModelSlot(slot, model: model)
                        }
                    )
                }
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var oauthToggleSection: some View {
        Toggle(isOn: Binding(
            get: { viewModel.currentConfiguration?.useOAuth ?? true },
            set: { viewModel.currentConfiguration?.useOAuth = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.useOAuth".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("agents.useOAuthDesc".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var manualPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.rawConfigs".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                if let config = previewConfig, !config.rawConfigs.isEmpty {
                    Button {
                        copyPreviewToClipboard()
                    } label: {
                        Label("action.copyAll".localized(), systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            if let config = previewConfig, !config.rawConfigs.isEmpty {
                if config.rawConfigs.count > 1 {
                    Picker("Config", selection: $viewModel.selectedRawConfigIndex) {
                        ForEach(config.rawConfigs.indices, id: \.self) { index in
                            Text(config.rawConfigs[index].filename ?? "Config \(index + 1)")
                                .tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                if viewModel.selectedRawConfigIndex < config.rawConfigs.count {
                    RawConfigView(config: config.rawConfigs[viewModel.selectedRawConfigIndex]) {
                        copyPreviewToClipboard(index: viewModel.selectedRawConfigIndex)
                    }
                }
            } else {
                HStack {
                    SmallProgressView()
                    Text("Generating preview...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private func copyPreviewToClipboard(index: Int? = nil) {
        guard let config = previewConfig else { return }
        
        let content: String
        if let idx = index, idx < config.rawConfigs.count {
            content = config.rawConfigs[idx].content
        } else {
            content = config.rawConfigs.map { $0.content }.joined(separator: "\n\n---\n\n")
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
    
    private var testConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.testConnection".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isTesting {
                            SmallProgressView()
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text("agents.test".localized())
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isTesting)
            }
            
            if let result = viewModel.testResult {
                TestResultView(result: result)
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    @ViewBuilder
    private var resultView: some View {
        if isSuccess {
            successResultView
        } else {
            errorResultView
        }
    }
    
    private var successResultView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                
                Text("agents.configSuccess".localized())
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            
            if let result = viewModel.configResult {
                Text(result.instructions)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                
                if result.mode == .automatic {
                    automaticModeResult(result)
                }
                
                if result.mode == .manual && !result.rawConfigs.isEmpty {
                    manualModeResult(result)
                }
            }
        }
    }
    
    private func automaticModeResult(_ result: AgentConfigResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.filesModified".localized())
                .font(.subheadline)
                .fontWeight(.medium)
            
            VStack(alignment: .leading, spacing: 6) {
                if let configPath = result.configPath {
                    FilePathRow(icon: "doc.fill", label: "Config", path: configPath)
                }
                
                if let authPath = result.authPath {
                    FilePathRow(icon: "key.fill", label: "Auth", path: authPath)
                }
                
                if result.shellConfig != nil {
                    FilePathRow(icon: "terminal", label: "Shell", path: viewModel.detectedShell.profilePath)
                }
                
                if let backupPath = result.backupPath {
                    FilePathRow(icon: "clock.arrow.circlepath", label: "Backup", path: backupPath)
                }
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private func manualModeResult(_ result: AgentConfigResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.rawConfigs".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button {
                    viewModel.copyAllRawConfigsToClipboard()
                } label: {
                    Label("action.copyAll".localized(), systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            if result.rawConfigs.count > 1 {
                Picker("Config", selection: $viewModel.selectedRawConfigIndex) {
                    ForEach(result.rawConfigs.indices, id: \.self) { index in
                        Text(result.rawConfigs[index].filename ?? "Config \(index + 1)")
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            if viewModel.selectedRawConfigIndex < result.rawConfigs.count {
                RawConfigView(config: result.rawConfigs[viewModel.selectedRawConfigIndex]) {
                    viewModel.copyRawConfigToClipboard(index: viewModel.selectedRawConfigIndex)
                }
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private var errorResultView: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            
            Text("agents.configFailed".localized())
                .font(.headline)
                .foregroundStyle(.red)
            
            if let error = viewModel.configResult?.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    
    private var footerView: some View {
        HStack {
            if hasResult {
                Spacer()
                
                Button("action.done".localized()) {
                    viewModel.dismissConfiguration()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            } else {
                Button("action.cancel".localized(), role: .cancel) {
                    viewModel.dismissConfiguration()
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button {
                    Task { await viewModel.applyConfiguration() }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isConfiguring {
                            SmallProgressView()
                        } else {
                            Image(systemName: viewModel.configurationMode == .automatic ? "gearshape.2" : "square.and.arrow.down")
                        }
                        Text(viewModel.configurationMode == .automatic ? "agents.apply".localized() : "agents.saveConfig".localized())
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(agent.color)
                .disabled(viewModel.isConfiguring)
                .keyboardShortcut(.return)
            }
        }
        .padding(16)
    }
}

private struct ModeButton: View {
    let mode: ConfigurationMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.title3)
                Text(mode.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.borderless)
    }
}

private struct StorageOptionButton: View {
    let option: ConfigStorageOption
    let isSelected: Bool
    let action: () -> Void
    
    private var displayName: String {
        switch option {
        case .jsonOnly: return "agents.storage.jsonOnly".localized()
        case .shellOnly: return "agents.storage.shellOnly".localized()
        case .both: return "agents.storage.both".localized()
        }
    }
    
    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.icon)
                    .font(.title3)
                Text(displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.borderless)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var isMasked: Bool = false
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(isMasked ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct ModelSlotRow: View {
    let slot: ModelSlot
    let selectedModel: String
    let availableModels: [AvailableModel]
    let onModelChange: (String) -> Void
    
    private var effectiveSelection: String {
        if !selectedModel.isEmpty {
            return selectedModel
        }
        return AvailableModel.defaultModels[slot]?.name ?? AvailableModel.allModels.first?.name ?? ""
    }
    
    var body: some View {
        HStack {
            Text(slot.displayName)
                .font(.caption)
                .fontWeight(.medium)
            
            Spacer(minLength: 12)
            
            Picker("", selection: Binding(
                get: { effectiveSelection },
                set: { onModelChange($0) }
            )) {
                let providers = Set(availableModels.map { $0.provider }).sorted()
                
                ForEach(providers, id: \.self) { provider in
                    Section(header: Text(provider.capitalized)) {
                        ForEach(availableModels.filter { $0.provider == provider }) { model in
                            Text(model.displayName)
                                .tag(model.name)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
        }
        .onAppear {
            if selectedModel.isEmpty {
                onModelChange(effectiveSelection)
            }
        }
    }
}

private struct TestResultView: View {
    let result: ConnectionTestResult
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
            
            Text(result.message)
                .font(.caption)
                .foregroundStyle(result.success ? .green : .red)
            
            Spacer()
            
            if let latency = result.latencyMs {
                Text("\(latency)ms")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FilePathRow: View {
    let icon: String
    let label: String
    let path: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .leading)
            
            Text(path)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct RawConfigView: View {
    let config: RawConfigOutput
    let onCopy: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let targetPath = config.targetPath {
                    Text(targetPath)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                Text(config.format.rawValue.uppercased())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                
                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            ScrollView {
                Text(config.content)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .frame(minHeight: 150, maxHeight: 320)
            .padding(10)
            .background(Color.black.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    AgentConfigSheet(
        viewModel: AgentSetupViewModel(),
        agent: .claudeCode
    )
}
