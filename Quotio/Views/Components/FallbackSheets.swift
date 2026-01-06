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
    let existingEntries: [FallbackEntry]
    let configuredProviders: [AIProvider]
    let proxyModels: [AvailableModel]
    let onAdd: (AIProvider, String) -> Void
    let onDismiss: () -> Void

    @State private var selectedProvider: AIProvider?
    @State private var modelName: String = ""
    @State private var showValidationError = false

    /// Providers that have configured accounts (from providerQuotas keys)
    private var availableProviders: [AIProvider] {
        configuredProviders
            .filter { !$0.isQuotaTrackingOnly }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Models available for the selected provider from proxy
    private var availableModels: [String] {
        guard let provider = selectedProvider else { return [] }

        // Filter models by provider name (case-insensitive match)
        let providerName = provider.rawValue.lowercased()
        return proxyModels
            .filter { model in
                // Match by provider field or by model ID prefix
                model.provider.lowercased() == providerName ||
                model.provider.lowercased().contains(providerName) ||
                model.id.lowercased().contains(providerName)
            }
            .map { $0.id }
            .sorted()
    }

    private var isValidEntry: Bool {
        selectedProvider != nil && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

            // Provider selection
            VStack(alignment: .leading, spacing: 6) {
                Text("fallback.selectProvider".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker("", selection: $selectedProvider) {
                    Text("fallback.selectProviderPlaceholder".localized())
                        .tag(nil as AIProvider?)

                    ForEach(availableProviders, id: \.self) { provider in
                        HStack {
                            ProviderIcon(provider: provider, size: 16)
                            Text(provider.displayName)
                        }
                        .tag(provider as AIProvider?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .frame(maxWidth: 320)

            // Model name input
            VStack(alignment: .leading, spacing: 6) {
                Text("fallback.modelId".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                if availableModels.isEmpty {
                    // Manual input when no models available
                    TextField("fallback.modelIdPlaceholder".localized(), text: $modelName)
                        .textFieldStyle(.roundedBorder)
                } else {
                    // Combo box with suggestions
                    HStack {
                        TextField("fallback.modelIdPlaceholder".localized(), text: $modelName)
                            .textFieldStyle(.roundedBorder)

                        Menu {
                            ForEach(availableModels, id: \.self) { model in
                                Button(model) {
                                    modelName = model
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }

                if showValidationError && !isValidEntry {
                    Text("fallback.entryRequired".localized())
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("fallback.modelIdHint".localized())
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
                    if isValidEntry {
                        onAdd(selectedProvider!, modelName.trimmingCharacters(in: .whitespacesAndNewlines))
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
        .onChange(of: selectedProvider) { _, newProvider in
            // Reset model name when provider changes
            modelName = ""
        }
    }
}

// MARK: - UUID Extension for Sheet Binding

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
