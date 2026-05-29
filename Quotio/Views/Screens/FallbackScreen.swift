//
//  FallbackScreen.swift
//  Quotio
//

import AppKit
import SwiftUI

struct FallbackScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = OperatingModeManager.shared
    @State private var configuration: VirtualModelsConfiguration?
    @State private var draft = VirtualModelsConfiguration()
    @State private var availableTargets: [VirtualModelAvailableTarget] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isLoadingTargets = false
    @State private var isPatchingEnabled = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var targetLoadError: String?
    @State private var savedAt: Date?
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isAutoSaveScheduled = false
    @State private var showCreateModelSheet = false
    @State private var editingModel: VirtualModelNameSelection?
    @State private var addingTargetsToModel: VirtualModelNameSelection?
    @State private var deletingModel: VirtualModelNameSelection?

    private var sortedModelNames: [String] {
        draft.virtualModels.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var validationMessages: [String] {
        VirtualModelsFormValidator.messages(for: draft)
    }

    private var hasLoadedConfiguration: Bool {
        configuration != nil
    }

    private var isDirty: Bool {
        guard let configuration else { return false }
        return draft != configuration
    }

    private var hasValidDirtyDraft: Bool {
        hasLoadedConfiguration && isDirty && validationMessages.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if isLoading && configuration == nil {
                    VirtualModelsLoadingView()
                } else if let loadError, configuration == nil {
                    VirtualModelsMessageView(
                        title: "virtualModels.loadFailed".localized(),
                        message: loadError,
                        actionTitle: "action.retry".localized(),
                        onAction: { Task { await loadConfiguration(force: true) } }
                    )
                } else {
                    content
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("fallback.title".localized())
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await loadConfiguration(force: true) }
                } label: {
                    Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isSaving)
                .help("virtualModels.refreshHelp".localized())

                Button {
                    showCreateModelSheet = true
                } label: {
                    Label("virtualModels.create".localized(), systemImage: "plus")
                }
                .disabled(!hasLoadedConfiguration || isSaving)
                .help("virtualModels.createHelp".localized())

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .help("virtualModels.saving".localized())
                }
            }
        }
        .task {
            await loadConfiguration(force: false)
        }
        .onDisappear {
            flushPendingAutosave()
        }
        .sheet(isPresented: $showCreateModelSheet) {
            VirtualModelNameSheet(
                mode: .create,
                existingNames: Set(draft.virtualModels.keys),
                originalName: nil
            ) { name in
                createModel(named: name)
            }
        }
        .sheet(item: $editingModel) { selection in
            VirtualModelNameSheet(
                mode: .edit,
                existingNames: Set(draft.virtualModels.keys),
                originalName: selection.name
            ) { name in
                renameModel(selection.name, to: name)
            }
        }
        .sheet(item: $addingTargetsToModel) { selection in
            VirtualModelTargetSheet(
                modelName: selection.name,
                availableTargets: availableTargets,
                existingTargets: draft.virtualModels[selection.name]?.targets.map(\.target) ?? []
            ) { targets in
                addTargets(targets, to: selection.name)
            }
        }
        .confirmationDialog(
            "virtualModels.deleteModelTitle".localized(),
            isPresented: Binding(
                get: { deletingModel != nil },
                set: { if !$0 { deletingModel = nil } }
            ),
            presenting: deletingModel
        ) { selection in
            Button("action.delete".localized(), role: .destructive) {
                deleteModel(selection.name)
                deletingModel = nil
            }
            Button("action.cancel".localized(), role: .cancel) {
                deletingModel = nil
            }
        } message: { selection in
            Text(String(format: "virtualModels.deleteModelMessage".localized(), selection.name))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let saveError {
            VirtualModelsBanner(
                title: "virtualModels.saveFailed".localized(),
                message: saveError,
                style: .error
            )
        } else if let targetLoadError {
            VirtualModelsBanner(
                title: "virtualModels.targetsLoadFailed".localized(),
                message: targetLoadError,
                style: .warning
            )
        } else if isSaving {
            VirtualModelsBanner(
                title: "virtualModels.saving".localized(),
                message: "virtualModels.savingDescription".localized(),
                style: .info
            )
        } else if let savedAt {
            VirtualModelsBanner(
                title: "virtualModels.saved".localized(),
                message: savedAt.formatted(date: .omitted, time: .shortened),
                style: .success
            )
        }

        if !validationMessages.isEmpty {
            VirtualModelsBanner(
                title: "virtualModels.invalidDraft".localized(),
                message: validationMessages.joined(separator: "\n"),
                style: .error
            )
        } else if isAutoSaveScheduled && isDirty {
            VirtualModelsBanner(
                title: "virtualModels.autoSavePending".localized(),
                message: "virtualModels.autoSavePendingDescription".localized(),
                style: .info
            )
        }

        VirtualModelsGlobalCard(
            enabled: draft.enabled,
            isUpdating: isPatchingEnabled,
            onToggle: { enabled in
                toggleGlobalRouting(enabled)
            }
        )

        VirtualModelsConfigurationCard(
            cacheTTL: Binding(
                get: { draft.cacheTTL },
                set: {
                    draft.cacheTTL = $0
                    markDraftChanged()
                }
            ),
            maxDepth: Binding(
                get: { draft.maxDepth },
                set: {
                    draft.maxDepth = $0
                    markDraftChanged()
                }
            )
        )

        modelsSection
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("fallback.title".localized())
                    .font(.title2.weight(.semibold))

                Text("virtualModels.description".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if isLoadingTargets {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(String(format: "virtualModels.targetsAvailableFormat".localized(), availableTargets.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await loadAvailableTargets() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoadingTargets || !hasLoadedConfiguration)
                .help("virtualModels.refreshTargets".localized())
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("virtualModels.configuredModels".localized())
                        .font(.headline)
                    Text("virtualModels.configuredModelsDescription".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showCreateModelSheet = true
                } label: {
                    Label("virtualModels.create".localized(), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
            }

            if sortedModelNames.isEmpty {
                VirtualModelsEmptyState {
                    showCreateModelSheet = true
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(sortedModelNames, id: \.self) { modelName in
                        if let model = draft.virtualModels[modelName] {
                            VirtualModelCard(
                                name: modelName,
                                model: model,
                                isGlobalEnabled: draft.enabled,
                                onToggleModel: { enabled in
                                    setModelEnabled(modelName, enabled: enabled)
                                },
                                onEdit: {
                                    editingModel = VirtualModelNameSelection(name: modelName)
                                },
                                onDelete: {
                                    deletingModel = VirtualModelNameSelection(name: modelName)
                                },
                                onAddTarget: {
                                    addingTargetsToModel = VirtualModelNameSelection(name: modelName)
                                },
                                onToggleTarget: { index, enabled in
                                    setTargetEnabled(modelName: modelName, index: index, enabled: enabled)
                                },
                                onMoveTarget: { index, direction in
                                    moveTarget(modelName: modelName, index: index, direction: direction)
                                },
                                onDeleteTarget: { index in
                                    deleteTarget(modelName: modelName, index: index)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func loadConfiguration(force: Bool) async {
        if isLoading { return }
        if !force, configuration != nil { return }

        isLoading = true
        loadError = nil
        saveError = nil
        targetLoadError = nil
        defer { isLoading = false }

        if modeManager.isLocalProxyMode && !viewModel.proxyManager.proxyStatus.running {
            await viewModel.ensureProxyRunning()
        }

        guard let client = viewModel.apiClient else {
            loadError = "models.proxyRequired".localized()
            return
        }

        do {
            let loaded = try await client.fetchVirtualModelsConfiguration()
            configuration = loaded
            draft = loaded
            savedAt = nil
            autoSaveTask?.cancel()
            autoSaveTask = nil
            isAutoSaveScheduled = false
        } catch APIError.httpError(404) {
            loadError = "Requires cpa++ API support."
            return
        } catch {
            loadError = error.localizedDescription
            return
        }

        await loadAvailableTargets()
    }

    @MainActor
    private func loadAvailableTargets() async {
        guard !isLoadingTargets else { return }
        guard let client = viewModel.apiClient else { return }

        isLoadingTargets = true
        targetLoadError = nil
        defer { isLoadingTargets = false }

        do {
            let response = try await client.fetchVirtualModelAvailableTargets()
            availableTargets = response.targets.sorted {
                $0.target.localizedCaseInsensitiveCompare($1.target) == .orderedAscending
            }
        } catch APIError.httpError(404) {
            targetLoadError = "Requires cpa++ API support."
        } catch {
            targetLoadError = error.localizedDescription
        }
    }

    @MainActor
    private func saveConfiguration() async {
        guard hasValidDirtyDraft, let client = viewModel.apiClient else { return }

        guard !isSaving else {
            scheduleAutosave()
            return
        }

        isSaving = true
        saveError = nil
        savedAt = nil
        autoSaveTask?.cancel()
        autoSaveTask = nil
        isAutoSaveScheduled = false
        defer { isSaving = false }

        let payload = VirtualModelsFormValidator.sanitized(draft)
        let currentDraft = { VirtualModelsFormValidator.sanitized(draft) }

        do {
            try await client.updateVirtualModelsConfiguration(payload)
            let savedConfiguration: VirtualModelsConfiguration
            do {
                savedConfiguration = try await client.fetchVirtualModelsConfiguration()
            } catch {
                savedConfiguration = payload
            }

            configuration = savedConfiguration
            if currentDraft() == payload {
                draft = savedConfiguration
                savedAt = Date()
            } else {
                savedAt = nil
                scheduleAutosave()
            }
            await loadAvailableTargets()
        } catch APIError.httpError(404) {
            saveError = "Requires cpa++ API support."
        } catch {
            saveError = error.localizedDescription
        }
    }

    @MainActor
    private func toggleGlobalRouting(_ enabled: Bool) {
        guard !isPatchingEnabled else { return }
        let previousValue = draft.enabled
        draft.enabled = enabled
        if var currentConfiguration = configuration {
            currentConfiguration.enabled = enabled
            configuration = currentConfiguration
        }
        saveError = nil
        savedAt = nil
        isPatchingEnabled = true

        Task { @MainActor in
            defer { isPatchingEnabled = false }
            guard let client = viewModel.apiClient else {
                draft.enabled = previousValue
                if var currentConfiguration = configuration {
                    currentConfiguration.enabled = previousValue
                    configuration = currentConfiguration
                }
                saveError = "models.proxyRequired".localized()
                return
            }

            do {
                try await client.setVirtualModelsEnabled(enabled)
            } catch {
                draft.enabled = previousValue
                if var currentConfiguration = configuration {
                    currentConfiguration.enabled = previousValue
                    configuration = currentConfiguration
                }
                saveError = error.localizedDescription
            }
        }
    }

    private func createModel(named name: String) {
        let sanitizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.virtualModels[sanitizedName] = VirtualModelRouteConfiguration(enabled: true, targets: [])
        markDraftChanged()
    }

    private func renameModel(_ currentName: String, to newName: String) {
        let sanitizedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitizedName != currentName,
              let model = draft.virtualModels.removeValue(forKey: currentName) else {
            return
        }
        draft.virtualModels[sanitizedName] = model
        markDraftChanged()
    }

    private func deleteModel(_ name: String) {
        draft.virtualModels.removeValue(forKey: name)
        markDraftChanged()
    }

    private func setModelEnabled(_ name: String, enabled: Bool) {
        guard var model = draft.virtualModels[name] else { return }
        model.enabled = enabled
        draft.virtualModels[name] = model
        markDraftChanged()
    }

    private func addTargets(_ targets: [String], to modelName: String) {
        guard var model = draft.virtualModels[modelName] else { return }
        var existing = Set(model.targets.map { $0.target.lowercased() })
        for target in targets {
            let sanitizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedTarget.isEmpty else { continue }
            guard !existing.contains(sanitizedTarget.lowercased()) else { continue }
            model.targets.append(VirtualModelTargetConfiguration(target: sanitizedTarget, enabled: true))
            existing.insert(sanitizedTarget.lowercased())
        }
        draft.virtualModels[modelName] = model
        markDraftChanged()
    }

    private func setTargetEnabled(modelName: String, index: Int, enabled: Bool) {
        guard var model = draft.virtualModels[modelName],
              model.targets.indices.contains(index) else { return }
        model.targets[index].enabled = enabled
        draft.virtualModels[modelName] = model
        markDraftChanged()
    }

    private func moveTarget(modelName: String, index: Int, direction: VirtualModelTargetMoveDirection) {
        guard var model = draft.virtualModels[modelName],
              model.targets.indices.contains(index) else { return }
        let destination = index + direction.rawValue
        guard model.targets.indices.contains(destination) else { return }
        model.targets.swapAt(index, destination)
        draft.virtualModels[modelName] = model
        markDraftChanged()
    }

    private func deleteTarget(modelName: String, index: Int) {
        guard var model = draft.virtualModels[modelName],
              model.targets.indices.contains(index) else { return }
        model.targets.remove(at: index)
        draft.virtualModels[modelName] = model
        markDraftChanged()
    }

    @MainActor
    private func markDraftChanged() {
        savedAt = nil
        saveError = nil
        scheduleAutosave()
    }

    @MainActor
    private func scheduleAutosave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        isAutoSaveScheduled = false

        guard hasValidDirtyDraft else { return }

        isAutoSaveScheduled = true
        autoSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                isAutoSaveScheduled = false
                return
            }

            guard !Task.isCancelled else {
                isAutoSaveScheduled = false
                return
            }

            isAutoSaveScheduled = false
            await saveConfiguration()
        }
    }

    @MainActor
    private func flushPendingAutosave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        isAutoSaveScheduled = false
        guard hasValidDirtyDraft else { return }
        Task { @MainActor in
            await saveConfiguration()
        }
    }
}

private struct VirtualModelNameSelection: Identifiable {
    let name: String
    var id: String { name }
}

enum VirtualModelTargetMoveDirection: Int {
    case up = -1
    case down = 1
}

private enum VirtualModelsBannerStyle {
    case error
    case warning
    case success
    case info

    var color: Color {
        switch self {
        case .error:
            return .red
        case .warning:
            return .orange
        case .success:
            return .green
        case .info:
            return .blue
        }
    }

    var iconName: String {
        switch self {
        case .error:
            return "exclamationmark.triangle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}

private struct VirtualModelsBanner: View {
    let title: String
    let message: String
    let style: VirtualModelsBannerStyle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.iconName)
                .foregroundStyle(style.color)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(style.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(style.color.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct VirtualModelsGlobalCard: View {
    let enabled: Bool
    let isUpdating: Bool
    var onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? .green : .secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("virtualModels.globalRouting".localized())
                    .font(.headline)
                Text("virtualModels.globalRoutingDescription".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    onToggle(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isUpdating)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct VirtualModelsConfigurationCard: View {
    @Binding var cacheTTL: String
    @Binding var maxDepth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("virtualModels.configuration".localized())
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("virtualModels.cacheTTL".localized())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("30s", text: $cacheTTL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140)
                    Text("virtualModels.cacheTTLHelp".localized())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("virtualModels.maxDepth".localized())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Stepper(value: $maxDepth, in: 1...50) {
                        Text("\(maxDepth)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 44, alignment: .leading)
                    }
                    .frame(width: 160)
                    Text("virtualModels.maxDepthHelp".localized())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }
}

private struct VirtualModelCard: View {
    let name: String
    let model: VirtualModelRouteConfiguration
    let isGlobalEnabled: Bool
    var onToggleModel: (Bool) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onAddTarget: () -> Void
    var onToggleTarget: (Int, Bool) -> Void
    var onMoveTarget: (Int, VirtualModelTargetMoveDirection) -> Void
    var onDeleteTarget: (Int) -> Void

    private var isEffectivelyEnabled: Bool {
        isGlobalEnabled && model.enabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(.headline, design: .monospaced))
                            .lineLimit(1)

                        VirtualModelStatusBadge(isEnabled: isEffectivelyEnabled)
                    }

                    Text(String(format: "virtualModels.targetCountFormat".localized(), model.targets.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { model.enabled },
                    set: { newValue in
                        onToggleModel(newValue)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("action.rename".localized())

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("action.delete".localized())

                Button {
                    onAddTarget()
                } label: {
                    Label("virtualModels.addTarget".localized(), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if model.targets.isEmpty {
                Text("virtualModels.noTargets".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                        VirtualModelTargetRow(
                            index: index,
                            target: target,
                            canMoveUp: index > 0,
                            canMoveDown: index < model.targets.count - 1,
                            onToggle: { enabled in
                                onToggleTarget(index, enabled)
                            },
                            onMove: { direction in
                                onMoveTarget(index, direction)
                            },
                            onDelete: {
                                onDeleteTarget(index)
                            }
                        )

                        if index < model.targets.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct VirtualModelTargetRow: View {
    let index: Int
    let target: VirtualModelTargetConfiguration
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onToggle: (Bool) -> Void
    var onMove: (VirtualModelTargetMoveDirection) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Circle())

            targetIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(target.target)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(targetKind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { target.enabled },
                set: { newValue in
                    onToggle(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(target.enabled ? "fallback.disable".localized() : "fallback.enable".localized())

            HStack(spacing: 2) {
                Button {
                    onMove(.up)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .help("virtualModels.moveUp".localized())

                Button {
                    onMove(.down)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .help("virtualModels.moveDown".localized())
            }
            .buttonStyle(.borderless)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("action.delete".localized())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(target.enabled ? 1 : 0.58)
    }

    @ViewBuilder
    private var targetIcon: some View {
        if let provider = providerID.flatMap(AIProvider.fromProviderID) {
            ProviderIcon(provider: provider, size: 22)
        } else {
            Image(systemName: target.target.contains("/") ? "square.stack.3d.up" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    private var providerID: String? {
        target.target.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    private var targetKind: String {
        target.target.contains("/")
            ? "virtualModels.concreteTarget".localized()
            : "virtualModels.nestedVirtualModel".localized()
    }
}

private struct VirtualModelStatusBadge: View {
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isEnabled ? .green : .secondary)
                .frame(width: 6, height: 6)
            Text(isEnabled ? "virtualModels.enabled".localized() : "virtualModels.disabled".localized())
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isEnabled ? .green : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((isEnabled ? Color.green : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct VirtualModelsEmptyState: View {
    var onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("virtualModels.emptyTitle".localized())
                    .font(.headline)
                Text("virtualModels.emptyDescription".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onCreate()
            } label: {
                Label("virtualModels.createFirst".localized(), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct VirtualModelsLoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("virtualModels.loading".localized())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
    }
}

private struct VirtualModelsMessageView: View {
    let title: String
    let message: String
    let actionTitle: String?
    var onAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let onAction {
                Button(actionTitle) {
                    onAction()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

@MainActor
private enum VirtualModelsFormValidator {
    static func sanitized(_ configuration: VirtualModelsConfiguration) -> VirtualModelsConfiguration {
        var next = configuration
        next.cacheTTL = next.cacheTTL.trimmingCharacters(in: .whitespacesAndNewlines)

        var sanitizedModels: [String: VirtualModelRouteConfiguration] = [:]
        for key in next.virtualModels.keys {
            guard var model = next.virtualModels[key] else { continue }
            let sanitizedName = key.trimmingCharacters(in: .whitespacesAndNewlines)
            model.targets = model.targets.map {
                VirtualModelTargetConfiguration(
                    target: $0.target.trimmingCharacters(in: .whitespacesAndNewlines),
                    enabled: $0.enabled
                )
            }
            sanitizedModels[sanitizedName] = model
        }
        next.virtualModels = sanitizedModels
        return next
    }

    static func messages(for configuration: VirtualModelsConfiguration) -> [String] {
        let sanitizedConfig = sanitized(configuration)
        var messages: [String] = []

        if sanitizedConfig.cacheTTL.isEmpty {
            messages.append("virtualModels.validation.cacheTTLRequired".localized())
        }

        if sanitizedConfig.maxDepth < 1 {
            messages.append("virtualModels.validation.maxDepthRequired".localized())
        }

        let names = sanitizedConfig.virtualModels.keys.map { $0.lowercased() }
        if Set(names).count != names.count {
            messages.append("virtualModels.validation.duplicateNames".localized())
        }

        for (name, model) in sanitizedConfig.virtualModels.sorted(by: { $0.key < $1.key }) {
            if name.isEmpty {
                messages.append("virtualModels.validation.nameRequired".localized())
            }
            if name.contains("/") {
                messages.append(String(format: "virtualModels.validation.nameNoSlashFormat".localized(), name))
            }
            if model.targets.isEmpty {
                messages.append(String(format: "virtualModels.validation.emptyTargetsFormat".localized(), name))
            }
            if model.targets.contains(where: { $0.target.isEmpty }) {
                messages.append(String(format: "virtualModels.validation.targetRequiredFormat".localized(), name))
            }
        }

        return messages
    }
}
