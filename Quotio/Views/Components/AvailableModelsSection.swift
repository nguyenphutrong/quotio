//
//  AvailableModelsSection.swift
//  Quotio
//
//  Dashboard section listing the model IDs the proxy reports on its
//  OpenAI-compatible /v1/models endpoint, with click-to-copy for pasting
//  into client configs.
//
//  The section shows only what that endpoint returned, and always states
//  whether the list is live or a stale leftover from an earlier fetch.
//

import QuotioDomain
import QuotioPresentation
import SwiftUI

struct AvailableModelsSection: View {
    @Environment(ProxyManagementScreenModel.self) private var proxyManagement
    @Environment(PasteboardAdapter.self) private var pasteboard

    @State private var state = ModelCatalogState()
    @State private var copiedModelId: String?

    private var isProxyRunning: Bool {
        proxyManagement.proxy.proxyStatus.running
    }

    private var showsOwnerColumn: Bool {
        state.entries.contains { $0.displayOwner != nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            header
        }
        .task(id: isProxyRunning) {
            guard isProxyRunning else {
                // Nothing on screen can be trusted once the proxy is down.
                state.reset()
                return
            }
            await loadIfNeeded()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Label("dashboard.availableModels".localized(), systemImage: "cpu")

            if !state.entries.isEmpty {
                Text(String(format: "availableModels.modelCount".localized(), state.entries.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(state.isLoading || !isProxyRunning)
            .help("action.refresh".localized())
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isProxyRunning {
            noteRow(icon: "pause.circle", text: "availableModels.proxyStopped".localized())
        } else if state.isLoading && !state.hasCompletedFetch {
            loadingRow
        } else if state.entries.isEmpty && state.lastFetchFailed {
            noteRow(icon: "exclamationmark.triangle", text: "availableModels.error".localized())
        } else if state.isEmptyLiveResult {
            freshnessRow
            noteRow(icon: "tray", text: "availableModels.empty".localized())
        } else if !state.entries.isEmpty {
            freshnessRow

            Text("availableModels.description".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(state.entries) { entry in
                modelRow(entry)
            }

            if showsOwnerColumn {
                Text("availableModels.ownerNote".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("availableModels.loading".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    /// States plainly whether the list below came from the proxy just now, or is
    /// a leftover from an earlier fetch that could no longer be refreshed.
    @ViewBuilder
    private var freshnessRow: some View {
        switch state.freshness {
        case .never:
            EmptyView()

        case .live(let fetchedAt):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                Text(String(format: "availableModels.live".localized(), timestamp(fetchedAt)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .stale(let fetchedAt):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(String(format: "availableModels.stale".localized(), timestamp(fetchedAt)))
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func modelRow(_ entry: ModelCatalogEntry) -> some View {
        Button {
            copyModelId(entry.id)
        } label: {
            HStack(spacing: 8) {
                Text(entry.id)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let owner = entry.displayOwner {
                    Text(String(format: "availableModels.owner".localized(), owner))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if copiedModelId == entry.id {
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

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func copyModelId(_ modelId: String) {
        pasteboard.copy(modelId)
        copiedModelId = modelId

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedModelId == modelId {
                copiedModelId = nil
            }
        }
    }

    private func loadIfNeeded() async {
        // A completed fetch is authoritative, including one that returned nothing,
        // so an empty catalog is not retried as if it had never been fetched.
        guard !state.hasCompletedFetch else { return }
        await load()
    }

    private func load() async {
        guard isProxyRunning, !state.isLoading else { return }

        state.beginLoading()
        do {
            let entries = try await proxyManagement.agentSetup.fetchModelCatalog()
            state.apply(entries: entries, fetchedAt: Date())
        } catch {
            state.applyFailure()
        }
    }
}
