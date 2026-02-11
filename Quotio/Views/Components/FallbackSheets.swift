//
//  FallbackSheets.swift
//  Quotio - Fallback Configuration Sheets
//

import SwiftUI

// MARK: - Virtual Model Sheet

struct VirtualModelSheet: View {
    let virtualModel: VirtualModel?
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var showValidationError = false

    private var isEditing: Bool {
        virtualModel != nil
    }

    private var isValidName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: isEditing ? "pencil.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text(isEditing ? "fallback.editVirtualModel".localized() : "fallback.createVirtualModel".localized())
                    .font(.title2)
                    .fontWeight(.bold)

                Text("fallback.virtualModelDescription".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Name input
            VStack(alignment: .leading, spacing: 6) {
                Text("fallback.modelName".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("fallback.modelNamePlaceholder".localized(), text: $name)
                    .textFieldStyle(.roundedBorder)

                if showValidationError && !isValidName {
                    Text("fallback.nameRequired".localized())
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("fallback.modelNameHint".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 320)

            // Buttons
            HStack(spacing: 16) {
                Button("action.cancel".localized(), role: .cancel) {
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button {
                    if isValidName {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        onDismiss()
                    } else {
                        showValidationError = true
                    }
                } label: {
                    Text(isEditing ? "action.save".localized() : "action.create".localized())
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidName)
            }
        }
        .padding(40)
        .frame(width: 440)
        .onAppear {
            if let model = virtualModel {
                name = model.name
            }
        }
    }
}

// MARK: - Add Fallback Entry Sheet

struct AddFallbackEntrySheet: View {
    let virtualModelId: UUID
    let virtualModelName: String
    let existingEntries: [FallbackEntry]
    let availableModels: [AvailableModel]
    let onAdd: (AIProvider, String) -> Void
    let onDismiss: () -> Void
    /// Optional async refresh callback. Returns `true` on success, `false` on failure.
    var onRefresh: (() async -> Bool)? = nil

    @State private var selectedModelId: String = ""
    @State private var showValidationError = false

    // MARK: Refresh State
    @State private var isRefreshing = false
    /// Transient feedback after refresh completes: nil = none, true = success, false = failure.
    @State private var refreshSuccess: Bool?

    /// The model type of the virtual model (determined by its name)
    private var virtualModelType: ModelType {
        ModelType.detect(from: virtualModelName)
    }

    private var existingModelIds: Set<String> {
        Set(existingEntries.map { $0.modelId })
    }

    private func isSelectableModel(_ model: AvailableModel) -> Bool {
        model.provider.lowercased() != "fallback" &&
        !existingModelIds.contains(model.id) &&
        ModelType.detect(from: model.id) == virtualModelType
    }

    /// Filter out virtual models, already added entries, and incompatible model types
    private var filteredModels: [AvailableModel] {
        availableModels.filter { isSelectableModel($0) }
    }

    /// Get the selected model object
    private var selectedModel: AvailableModel? {
        filteredModels.first { $0.id == selectedModelId }
    }

    /// Maps a model to its hosting AIProvider for icon display.
    ///
    /// Aggregator providers (Copilot, Antigravity, Kiro) host models from other providers,
    /// so their model IDs carry the underlying provider's prefix (e.g., Copilot's
    /// `claude-3.5-sonnet`). The `provider` field from the proxy API (`owned_by`) is the
    /// most reliable source and is checked first. Model ID prefix matching serves as a
    /// fallback for models with unknown or missing provider metadata.
    private func providerFromModel(_ model: AvailableModel) -> AIProvider {
        let providerName = model.provider.lowercased()
        let modelId = model.id.lowercased()

        // FIRST: Try exact match on provider field (most reliable — from proxy API owned_by)
        // e.g., "github-copilot" -> .copilot, "antigravity" -> .antigravity
        for provider in AIProvider.allCases {
            if provider.rawValue.lowercased() == providerName {
                return provider
            }
        }

        // SECOND: Try to match by model ID prefix (fallback for unknown provider strings)
        // e.g., "kiro-claude-xxx" -> kiro, "gemini-claude-xxx" -> gemini
        for provider in AIProvider.allCases {
            let providerKey = provider.rawValue.lowercased()
            if modelId.hasPrefix(providerKey + "-") || modelId.hasPrefix(providerKey + "_") {
                return provider
            }
        }

        // THIRD: Try to infer from model ID content (for models without prefix)
        if modelId.contains("kiro") {
            return .kiro
        } else if modelId.contains("gemini") {
            return .gemini
        } else if modelId.contains("copilot") {
            return .copilot
        } else if modelId.contains("codex") {
            return .codex
        }

        // Default to claude for generic claude models
        return .claude
    }

    private var isValidEntry: Bool {
        !selectedModelId.isEmpty && selectedModel != nil
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("fallback.addFallbackEntry".localized())
                    .font(.title2)
                    .fontWeight(.bold)

                Text("fallback.addEntryDescription".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Model selection
            VStack(alignment: .leading, spacing: 6) {
                Text("fallback.modelId".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                if filteredModels.isEmpty {
                    // Manual input when no models available
                    HStack(spacing: 8) {
                        Text("fallback.noModelsHint".localized())
                            .font(.caption)
                            .foregroundStyle(.orange)

                        if onRefresh != nil {
                            refreshButton
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    // Picker for model selection - grouped by provider
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedModelId) {
                            Text("fallback.selectModelPlaceholder".localized())
                                .tag("")

                            let providers = Set(filteredModels.map { $0.provider }).sorted()

                            ForEach(providers, id: \.self) { provider in
                                Section(header: Text(provider.capitalized)) {
                                    ForEach(filteredModels.filter { $0.provider == provider }) { model in
                                        Text(model.displayName)
                                            .tag(model.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if onRefresh != nil {
                            refreshButton
                        }
                    }
                }

                if showValidationError && !isValidEntry {
                    Text("fallback.entryRequired".localized())
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Show selected model info
                if let model = selectedModel {
                    HStack(spacing: 8) {
                        let provider = providerFromModel(model)
                        ProviderIcon(provider: provider, size: 16)
                        Text(provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("→")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(model.id)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 400)

            // Buttons
            HStack(spacing: 16) {
                Button("action.cancel".localized(), role: .cancel) {
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button {
                    if isValidEntry, let model = selectedModel {
                        let provider = providerFromModel(model)
                        onAdd(provider, model.id)
                        onDismiss()
                    } else {
                        showValidationError = true
                    }
                } label: {
                    Label("fallback.addEntry".localized(), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidEntry)
            }
        }
        .padding(40)
        .frame(width: 480)
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button {
            guard !isRefreshing else { return }
            isRefreshing = true
            refreshSuccess = nil

            Task {
                let success = await onRefresh?() ?? false

                await MainActor.run {
                    isRefreshing = false
                    refreshSuccess = success

                    // Clear invalid selection after model list updates
                    if selectedModel == nil {
                        selectedModelId = ""
                    }
                }

                // Show feedback icon briefly, then clear
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) {
                        refreshSuccess = nil
                    }
                }
            }
        } label: {
            Group {
                if let success = refreshSuccess {
                    Image(systemName: success ? "checkmark" : "xmark")
                        .foregroundStyle(success ? .green : .red)
                } else if isRefreshing {
                    // TimelineView drives per-frame rotation for smooth continuous spin
                    TimelineView(.animation) { context in
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(
                                context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 1) * 360
                            ))
                    }
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRefreshing || refreshSuccess != nil)
    }
}

// MARK: - UUID Extension for Sheet Binding

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
