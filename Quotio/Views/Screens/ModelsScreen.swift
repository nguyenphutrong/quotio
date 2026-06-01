//
//  ModelsScreen.swift
//  Quotio
//
//  Backend-backed provider model catalog.
//

import AppKit
import SwiftUI

struct ModelsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var catalog: ManagementModelCatalog?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var modelActionError: String?
    @State private var updatingModelIDs: Set<String> = []

    private var rows: [ManagementModelCatalogItem] {
        catalog?.rows ?? []
    }

    private var filteredRows: [ManagementModelCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visibleRows = query.isEmpty ? rows : rows.filter { row in
            [
                row.providerName,
                row.providerID,
                row.modelID,
                row.routeID,
                row.displayName ?? "",
                row.ownedBy ?? ""
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }

        return visibleRows.sorted {
            if $0.providerName != $1.providerName {
                return $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
            }
            return $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelsScreenHeader(
                    isRefreshing: isLoading,
                    onRefresh: {
                        Task { await loadModels(force: true) }
                    }
                )

                ModelsSearchField(text: $searchText)

                ModelsTable(
                    rows: filteredRows,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    isFiltered: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    hasLoadedRows: !rows.isEmpty,
                    updatingModelIDs: updatingModelIDs,
                    onRetry: {
                        Task { await loadModels(force: true) }
                    },
                    onToggleModel: { row in
                        Task { await toggleModel(row) }
                    }
                )
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("nav.models".localized())
        .task {
            await loadModels(force: false)
        }
        .alert("models.updateFailed".localized(), isPresented: Binding(
            get: { modelActionError != nil },
            set: { if !$0 { modelActionError = nil } }
        )) {
            Button("OK", role: .cancel) {
                modelActionError = nil
            }
        } message: {
            Text(modelActionError ?? "")
        }
    }

    @MainActor
    private func loadModels(force: Bool) async {
        if isLoading { return }
        if !force, catalog != nil { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let readiness = await modelsAPIClient()
        guard let client = readiness.client else {
            errorMessage = readiness.errorMessage
            return
        }

        do {
            catalog = try await client.fetchModelCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleModel(_ row: ManagementModelCatalogItem) async {
        guard row.isAvailable else { return }
        guard !updatingModelIDs.contains(row.id) else { return }
        let readiness = await modelsAPIClient()
        guard let client = readiness.client else {
            modelActionError = readiness.errorMessage
            return
        }

        let providerRows = rows.filter { $0.providerID == row.providerID }
        guard !providerRows.isEmpty else { return }

        updatingModelIDs.insert(row.id)
        defer { updatingModelIDs.remove(row.id) }

        do {
            let allModelIDs = Set(providerRows.map(\.modelID))
            var enabledModelIDs = Set(providerRows.filter(\.isEnabled).map(\.modelID))
            if row.isEnabled {
                enabledModelIDs.remove(row.modelID)
            } else {
                enabledModelIDs.insert(row.modelID)
            }

            let enabledPayload: [String]? = enabledModelIDs == allModelIDs
                ? nil
                : enabledModelIDs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

            try await client.updateProviderEnabledModels(providerID: row.providerID, enabledModels: enabledPayload)
            catalog = try await client.fetchModelCatalog()
        } catch APIError.httpError(404) {
            modelActionError = "models.error.enableDisableUnsupported".localized()
        } catch {
            modelActionError = error.localizedDescription
        }
    }

    @MainActor
    private func modelsAPIClient() async -> (client: ManagementAPIClient?, errorMessage: String?) {
        await viewModel.managementAPIClientForAction(
            bundleMissingMessage: "models.error.bundleMissing".localized(),
            startLocalMessage: "models.error.startLocal".localized(),
            remoteDisconnectedMessage: "models.error.remoteDisconnected".localized(),
            connectMessage: "models.error.connectToCPA".localized()
        )
    }
}

private enum ModelsTableMetrics {
    static let providerWidth: CGFloat = 230
    static let capabilitiesWidth: CGFloat = 132
    static let statusWidth: CGFloat = 132
    static let columnSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 14
    static let headerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 46
}

private struct ModelsScreenHeader: View {
    let isRefreshing: Bool
    var onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("models.title".localized())
                    .font(.title2.weight(.semibold))

                Text("models.description".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onRefresh()
            } label: {
                Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    .frame(minWidth: 86)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isRefreshing)
            .help("models.refreshHelp".localized())
        }
    }
}

private struct ModelsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("models.searchPlaceholder".localized(), text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(width: 380, height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ModelsTable: View {
    let rows: [ManagementModelCatalogItem]
    let isLoading: Bool
    let errorMessage: String?
    let isFiltered: Bool
    let hasLoadedRows: Bool
    let updatingModelIDs: Set<String>
    var onRetry: () -> Void
    var onToggleModel: (ManagementModelCatalogItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModelsTableHeader()

            Divider()

            if isLoading && rows.isEmpty {
                ModelsLoadingRow()
            } else if let errorMessage {
                ModelsMessageRow(
                    title: "models.failedToLoad".localized(),
                    message: errorMessage,
                    actionTitle: "action.retry".localized(),
                    onAction: onRetry
                )
            } else if rows.isEmpty {
                ModelsMessageRow(
                    title: isFiltered ? "models.noMatches".localized() : "models.emptyTitle".localized(),
                    message: hasLoadedRows ? "models.noMatchesDescription".localized() : "models.emptyDescription".localized(),
                    actionTitle: nil,
                    onAction: nil
                )
            } else {
                ForEach(rows) { row in
                    ModelsTableRow(
                        row: row,
                        isUpdating: updatingModelIDs.contains(row.id),
                        onToggleModel: onToggleModel
                    )
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ModelsTableHeader: View {
    var body: some View {
        ModelsTableGrid {
            Text("models.columns.provider".localized())
                .modelsHeaderStyle()
                .frame(width: ModelsTableMetrics.providerWidth, alignment: .leading)

            Text("models.columns.model".localized())
                .modelsHeaderStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("models.columns.capabilities".localized())
                .modelsHeaderStyle()
                .frame(width: ModelsTableMetrics.capabilitiesWidth, alignment: .leading)

            Text("models.columns.status".localized())
                .modelsHeaderStyle()
                .frame(width: ModelsTableMetrics.statusWidth, alignment: .leading)
        }
        .frame(height: ModelsTableMetrics.headerHeight)
    }
}

private struct ModelsTableRow: View {
    let row: ManagementModelCatalogItem
    let isUpdating: Bool
    var onToggleModel: (ManagementModelCatalogItem) -> Void
    @State private var didCopyModelID = false

    var body: some View {
        ModelsTableGrid {
            providerColumn
                .frame(width: ModelsTableMetrics.providerWidth, alignment: .leading)

            modelColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            CapabilityBadgeGroup(capabilities: row.capabilities)
                .frame(width: ModelsTableMetrics.capabilitiesWidth, alignment: .leading)

            statusColumn
                .frame(width: ModelsTableMetrics.statusWidth, alignment: .leading)
        }
        .frame(minHeight: ModelsTableMetrics.rowHeight)
    }

    @ViewBuilder
    private var providerColumn: some View {
        HStack(spacing: 10) {
            if let provider = AIProvider.fromProviderID(row.providerID) {
                ProviderIcon(provider: provider, size: 22)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            Text(row.providerName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.routeID)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button {
                    copyModelID()
                } label: {
                    Image(systemName: didCopyModelID ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(didCopyModelID ? .green : .secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("models.copyModelID".localized())
            }

            if let detail = modelDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var modelDetail: String? {
        var parts: [String] = []
        if let displayName = row.displayName, !displayName.isEmpty, displayName != row.modelID {
            parts.append(displayName)
        }
        if let contextLength = row.contextLength, contextLength > 0 {
            parts.append("\(contextLength.formatted()) ctx")
        }
        if let maxOutputTokens = row.maxOutputTokens, maxOutputTokens > 0 {
            parts.append("\(maxOutputTokens.formatted()) out")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    @ViewBuilder
    private var statusColumn: some View {
        if row.isAvailable {
            Button {
                onToggleModel(row)
            } label: {
                ModelStatusBadge(isAvailable: row.isAvailable, isEnabled: row.isEnabled, isUpdating: isUpdating)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .help(row.isEnabled ? "models.disableModelHelp".localized() : "models.enableModelHelp".localized())
        } else {
            ModelStatusBadge(isAvailable: row.isAvailable, isEnabled: row.isEnabled, isUpdating: false)
                .help("models.status.unavailable".localized())
        }
    }

    private func copyModelID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.routeID, forType: .string)
        didCopyModelID = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopyModelID = false
        }
    }
}

private struct ModelsTableGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: ModelsTableMetrics.columnSpacing) {
            content
        }
        .padding(.horizontal, ModelsTableMetrics.horizontalPadding)
    }
}

private struct CapabilityBadgeGroup: View {
    let capabilities: [ManagementModelCapability]

    var body: some View {
        if capabilities.isEmpty {
            Text("-")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 5) {
                ForEach(capabilities) { capability in
                    Text(capability.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(capabilityColor(capability.id))
                        .frame(minWidth: capability.label.count > 1 ? 22 : 18, minHeight: 18)
                        .background(capabilityColor(capability.id).opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .help(capability.localizationKey.localized())
                }
            }
        }
    }

    private func capabilityColor(_ id: String) -> Color {
        switch id {
        case "reasoning":
            return .orange
        case "vision":
            return .purple
        case "tools":
            return .red
        case "free":
            return .green
        case "embedding", "rerank":
            return .yellow
        default:
            return .secondary
        }
    }
}

private struct ModelStatusBadge: View {
    let isAvailable: Bool
    let isEnabled: Bool
    let isUpdating: Bool

    var body: some View {
        let title = statusTitle
        HStack(spacing: 5) {
            if isUpdating {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: statusIcon)
                    .font(.caption.weight(.semibold))
            }
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.14))
        .clipShape(Capsule())
    }

    private var statusTitle: String {
        if isUpdating { return "models.status.updating".localized() }
        if !isAvailable { return "models.status.unavailable".localized() }
        return isEnabled ? "models.status.enabled".localized() : "models.status.disabled".localized()
    }

    private var statusIcon: String {
        if !isAvailable { return "exclamationmark.circle" }
        return isEnabled ? "checkmark.circle" : "pause.circle"
    }

    private var statusColor: Color {
        if !isAvailable { return .orange }
        return isEnabled ? .green : .secondary
    }
}

private struct ModelsLoadingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("models.loading".localized())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .center)
    }
}

private struct ModelsMessageRow: View {
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
                .help(actionTitle)
            }
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private extension View {
    func modelsHeaderStyle() -> some View {
        self
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }
}
