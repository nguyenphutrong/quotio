//
//  FallbackScreen.swift
//  Quotio - Model Fallback Configuration
//

import SwiftUI

struct FallbackScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var fallbackSettings = FallbackSettingsManager.shared
    @State private var showAddVirtualModelSheet = false
    @State private var editingVirtualModel: VirtualModel?
    @State private var showAddEntrySheet = false
    @State private var addingEntryToModelId: UUID?
    @State private var showReconfigureAlert = false
    @State private var showDuplicateNameAlert = false
    @State private var previousFallbackEnabled: Bool?

    /// Check if Bridge Mode is enabled
    private var isBridgeModeEnabled: Bool {
        viewModel.proxyManager.useBridgeMode
    }

    /// Get available models from AgentSetupViewModel
    private var availableModels: [AvailableModel] {
        viewModel.agentSetupViewModel.availableModels
    }

    var body: some View {
        List {
            // Section 1: Global Settings
            globalSettingsSection

            // Section 2: Active Route Status (only show when there are active routes)
            if fallbackSettings.isEnabled && !fallbackSettings.activeRouteStates.isEmpty {
                activeRouteStatusSection
            }

            // Section 3: Virtual Models
            virtualModelsSection
        }
        .navigationTitle("fallback.title".localized())
        .toolbar {
            toolbarContent
        }
        .sheet(isPresented: $showAddVirtualModelSheet) {
            VirtualModelSheet(
                virtualModel: nil,
                onSave: { name in
                    if fallbackSettings.addVirtualModel(name: name) == nil {
                        showDuplicateNameAlert = true
                    }
                },
                onDismiss: {
                    showAddVirtualModelSheet = false
                }
            )
        }
        .sheet(item: $editingVirtualModel) { model in
            VirtualModelSheet(
                virtualModel: model,
                onSave: { name in
                    if !fallbackSettings.renameVirtualModel(id: model.id, newName: name) {
                        showDuplicateNameAlert = true
                    }
                },
                onDismiss: {
                    editingVirtualModel = nil
                }
            )
        }
        .sheet(item: $addingEntryToModelId) { modelId in
            let virtualModel = fallbackSettings.virtualModels.first(where: { $0.id == modelId })
            AddFallbackEntrySheet(
                virtualModelId: modelId,
                virtualModelName: virtualModel?.name ?? "",
                existingEntries: virtualModel?.fallbackEntries ?? [],
                availableModels: availableModels,
                onAdd: { provider, modelName in
                    fallbackSettings.addFallbackEntry(to: modelId, provider: provider, modelName: modelName)
                },
                onDismiss: {
                    addingEntryToModelId = nil
                }
            )
        }
        .task {
            await loadModelsIfNeeded()
        }
        // Alert when Fallback toggle changes
        .alert("fallback.reconfigureRequired".localized(), isPresented: $showReconfigureAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text("fallback.reconfigureMessage".localized())
        }
        // Alert when duplicate virtual model name
        .alert("fallback.duplicateName".localized(), isPresented: $showDuplicateNameAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text("fallback.duplicateNameMessage".localized())
        }
    }

    // MARK: - Load Models

    private func loadModelsIfNeeded() async {
        // Load models using AgentSetupViewModel if not already loaded
        let agentVM = viewModel.agentSetupViewModel
        if agentVM.availableModels.isEmpty {
            guard viewModel.proxyManager.proxyStatus.running else { return }
            await agentVM.loadModels(forceRefresh: false)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddVirtualModelSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .help("fallback.addVirtualModel".localized())
            .disabled(!fallbackSettings.isEnabled)
        }
    }

    // MARK: - Global Settings Section

    @ViewBuilder
    private var globalSettingsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { fallbackSettings.configuration.isEnabled },
                set: { newValue in
                    // Only allow enabling if Bridge Mode is enabled
                    guard isBridgeModeEnabled || !newValue else { return }

                    let oldValue = fallbackSettings.configuration.isEnabled
                    fallbackSettings.configuration.isEnabled = newValue
                    // Show reconfigure alert when toggle changes
                    if oldValue != newValue {
                        showReconfigureAlert = true
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("fallback.enableFallback".localized())
                            .fontWeight(.medium)
                        ExperimentalBadge()
                    }
                    Text("fallback.enableDescription".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!isBridgeModeEnabled)

            // Bridge Mode warning - show when Bridge Mode is disabled
            if !isBridgeModeEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("fallback.bridgeModeRequired".localized())
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("fallback.bridgeModeRequiredDesc".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("fallback.settings".localized(), systemImage: "gearshape")
        }
    }

    // MARK: - Active Route Status Section

    @ViewBuilder
    private var activeRouteStatusSection: some View {
        Section {
            ForEach(fallbackSettings.activeRouteStates, id: \.virtualModelName) { state in
                HStack(spacing: 12) {
                    // Provider icon
                    ProviderIcon(provider: state.currentEntry.provider, size: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        // Virtual model name
                        Text(state.virtualModelName)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        // Current route
                        HStack(spacing: 4) {
                            Text(state.displayString)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("(\(state.progressString))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    // Status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                        Text("fallback.routeActive".localized())
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            // Clear all button
            Button(role: .destructive) {
                fallbackSettings.clearAllRouteStates()
            } label: {
                Label("fallback.clearRouteStates".localized(), systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
            }
        } header: {
            HStack {
                Label("fallback.activeRoutes".localized(), systemImage: "arrow.triangle.swap")
                Spacer()
                Text("\(fallbackSettings.activeRouteStates.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        } footer: {
            Text("fallback.activeRoutesFooter".localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Virtual Models Section

    @ViewBuilder
    private var virtualModelsSection: some View {
        Section {
            if fallbackSettings.virtualModels.isEmpty {
                VirtualModelsEmptyState(
                    isEnabled: fallbackSettings.isEnabled,
                    onAdd: {
                        showAddVirtualModelSheet = true
                    }
                )
            } else {
                ForEach(fallbackSettings.virtualModels) { model in
                    VirtualModelRow(
                        model: model,
                        isGlobalEnabled: fallbackSettings.isEnabled,
                        onToggle: {
                            fallbackSettings.toggleVirtualModel(id: model.id)
                        },
                        onEdit: {
                            editingVirtualModel = model
                        },
                        onDelete: {
                            fallbackSettings.removeVirtualModel(id: model.id)
                        },
                        onAddEntry: {
                            addingEntryToModelId = model.id
                        },
                        onDeleteEntry: { entryId in
                            fallbackSettings.removeFallbackEntry(from: model.id, entryId: entryId)
                        },
                        onMoveEntry: { source, destination in
                            fallbackSettings.moveFallbackEntry(in: model.id, from: source, to: destination)
                        }
                    )
                }
            }
        } header: {
            HStack {
                Label("fallback.virtualModels".localized(), systemImage: "arrow.triangle.branch")

                if !fallbackSettings.virtualModels.isEmpty {
                    Spacer()
                    Text("\(fallbackSettings.virtualModels.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("fallback.virtualModelsFooter".localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Virtual Models Empty State

struct VirtualModelsEmptyState: View {
    let isEnabled: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("fallback.noVirtualModels".localized())
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("fallback.noVirtualModelsDescription".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            if isEnabled {
                Button {
                    onAdd()
                } label: {
                    Label("fallback.createFirst".localized(), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("fallback.enableFirst".localized())
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Virtual Model Row

struct VirtualModelRow: View {
    let model: VirtualModel
    let isGlobalEnabled: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAddEntry: () -> Void
    let onDeleteEntry: (UUID) -> Void
    let onMoveEntry: (IndexSet, Int) -> Void

    @State private var isExpanded = true
    @State private var showDeleteConfirmation = false

    private var isEffectivelyEnabled: Bool {
        isGlobalEnabled && model.isEnabled
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Fallback entries list
            ForEach(model.sortedEntries) { entry in
                FallbackEntryRow(
                    entry: entry,
                    isEnabled: isEffectivelyEnabled,
                    onDelete: {
                        onDeleteEntry(entry.id)
                    }
                )
            }
            .onMove { source, destination in
                onMoveEntry(source, destination)
            }

            // Add entry button
            Button {
                onAddEntry()
            } label: {
                Label("fallback.addEntry".localized(), systemImage: "plus.circle")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(!isGlobalEnabled)
            .padding(.leading, 4)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 12) {
                // Model name
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .fontWeight(.medium)
                            .foregroundStyle(isEffectivelyEnabled ? .primary : .secondary)

                        if !model.isEnabled {
                            Text("fallback.disabled".localized())
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }

                    Text("\(model.fallbackEntries.count) " + "fallback.entries".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Toggle button
                Button {
                    onToggle()
                } label: {
                    Image(systemName: model.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.isEnabled && isGlobalEnabled ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isGlobalEnabled)
            }
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("action.rename".localized(), systemImage: "pencil")
            }

            Button {
                onToggle()
            } label: {
                Label(model.isEnabled ? "fallback.disable".localized() : "fallback.enable".localized(),
                      systemImage: model.isEnabled ? "xmark.circle" : "checkmark.circle")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("action.delete".localized(), systemImage: "trash")
            }
        }
        .confirmationDialog("fallback.deleteConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("fallback.deleteMessage".localized())
        }
    }
}

// MARK: - Fallback Entry Row

struct FallbackEntryRow: View {
    let entry: FallbackEntry
    let isEnabled: Bool
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Priority badge
            Text("\(entry.priority)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(isEnabled ? entry.provider.color.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundStyle(isEnabled ? entry.provider.color : .secondary)
                .clipShape(Circle())

            // Provider icon
            ProviderIcon(provider: entry.provider, size: 24)
                .opacity(isEnabled ? 1 : 0.5)

            // Entry info
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.provider.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                Text(entry.modelId)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Delete button
            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .confirmationDialog("fallback.deleteEntryConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        }
    }
}
