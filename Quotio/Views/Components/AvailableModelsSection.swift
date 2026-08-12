//
//  AvailableModelsSection.swift
//  Quotio
//
//  Dashboard section listing the model IDs usable through the proxy,
//  grouped by provider, with click-to-copy for pasting into configs.
//

import SwiftUI

struct AvailableModelsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel

    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var copiedModelId: String?

    private var isProxyRunning: Bool {
        viewModel.proxyManager.proxyStatus.running
    }

    private var modelGroups: [ProviderModelGroup] {
        ModelCatalog.groupByProvider(viewModel.agentSetupViewModel.availableModels)
    }

    private var totalModelCount: Int {
        modelGroups.reduce(0) { $0 + $1.models.count }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if !isProxyRunning {
                    noteRow(icon: "pause.circle", text: "availableModels.proxyStopped".localized())
                } else if isLoading && modelGroups.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("availableModels.loading".localized())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else if loadFailed {
                    noteRow(icon: "exclamationmark.triangle", text: "availableModels.error".localized())
                } else if modelGroups.isEmpty {
                    noteRow(icon: "tray", text: "availableModels.empty".localized())
                } else {
                    Text("availableModels.description".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(modelGroups) { group in
                        providerGroupView(group)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Label("dashboard.availableModels".localized(), systemImage: "cpu")

                if totalModelCount > 0 {
                    Text(String(format: "availableModels.modelCount".localized(), totalModelCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await loadModels(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading || !isProxyRunning)
                .help("action.refresh".localized())
            }
        }
        .task {
            await loadModelsIfNeeded()
        }
    }

    // MARK: - Subviews

    private func providerGroupView(_ group: ProviderModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.provider)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(group.models) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: AvailableModel) -> some View {
        Button {
            copyModelId(model.id)
        } label: {
            HStack(spacing: 8) {
                Text(model.id)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if copiedModelId == model.id {
                    Label("availableModels.copied".localized(), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("action.copy".localized())
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func copyModelId(_ modelId: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelId, forType: .string)
        copiedModelId = modelId

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedModelId == modelId {
                copiedModelId = nil
            }
        }
    }

    private func loadModelsIfNeeded() async {
        guard isProxyRunning else { return }
        guard viewModel.agentSetupViewModel.availableModels.isEmpty else { return }
        await loadModels(force: false)
    }

    private func loadModels(force: Bool) async {
        guard isProxyRunning else { return }
        isLoading = true
        defer { isLoading = false }

        let loadedFromRemote = await viewModel.agentSetupViewModel.loadModels(forceRefresh: force)
        loadFailed = !loadedFromRemote
    }
}
