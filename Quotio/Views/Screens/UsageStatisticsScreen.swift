//
//  UsageStatisticsScreen.swift
//  Quotio
//

import SwiftUI

struct UsageStatisticsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = OperatingModeManager.shared

    @State private var status: UsageStatsStatus?
    @State private var summary: UsageStatsSummary?
    @State private var events: [UsageStatsEvent] = []
    @State private var syncResult: UsageStatsModelPricesSyncResult?

    @State private var accountFilter = ""
    @State private var modelFilter = ""
    @State private var channelFilter = ""
    @State private var authIndexFilter = ""
    @State private var useStartDate = false
    @State private var useEndDate = false
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var selectedLimit = 100
    @State private var offset = 0

    @State private var isLoadingData = false
    @State private var isSyncingPrices = false
    @State private var dataError: String?
    @State private var pricesError: String?

    private let limitOptions = [50, 100, 250, 500, 1000]

    var body: some View {
        Group {
            if modeManager.isLocalProxyMode && !viewModel.proxyManager.proxyStatus.running {
                ProxyRequiredView(description: "usageStats.startProxy".localized()) {
                    await viewModel.ensureProxyRunning()
                }
            } else if viewModel.apiClient == nil {
                ContentUnavailableView {
                    Label("usageStats.managementUnavailable.title".localized(), systemImage: "network.slash")
                } description: {
                    Text("usageStats.managementUnavailable.description".localized())
                } actions: {
                    Button("action.retry".localized()) {
                        Task { await viewModel.initialize() }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        filtersSection

                        if isDisabledState {
                            disabledStateView
                        } else if let dataError {
                            errorSection(dataError) {
                                Task { await loadData(resetOffset: false) }
                            }
                        } else {
                            summarySection
                            eventsSection
                        }

                        if !isDisabledState && !isUnsupportedState {
                            costEstimationSection
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .navigationTitle("nav.usageStatistics".localized())
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await loadAll(resetOffset: false) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("action.refresh".localized())
                .disabled(isLoadingData || viewModel.apiClient == nil)
            }
        }
        .task {
            await loadAll(resetOffset: true)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("usageStats.title".localized())
                    .font(.title2.weight(.semibold))
                Text("usageStats.description".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let status {
                StatusBadge(status: status)
            }
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("usageStats.filters.title".localized(), systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Spacer()
                Button("usageStats.filters.reset".localized()) {
                    resetFilters()
                    Task { await loadData(resetOffset: true) }
                }
                .buttonStyle(.borderless)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    filterTextField("usageStats.filters.account".localized(), text: $accountFilter)
                    filterTextField("usageStats.filters.model".localized(), text: $modelFilter)
                    filterTextField("usageStats.filters.channel".localized(), text: $channelFilter)
                    filterTextField("usageStats.filters.authIndex".localized(), text: $authIndexFilter)
                }

                GridRow {
                    Toggle("usageStats.filters.start".localized(), isOn: $useStartDate)
                    DatePicker("", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .disabled(!useStartDate)

                    Toggle("usageStats.filters.end".localized(), isOn: $useEndDate)
                    DatePicker("", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .disabled(!useEndDate)
                }
            }

            HStack {
                Picker("usageStats.limit".localized(), selection: $selectedLimit) {
                    ForEach(limitOptions, id: \.self) { limit in
                        Text("\(limit)").tag(limit)
                    }
                }
                .frame(width: 160)

                Spacer()

                Button("usageStats.filters.apply".localized()) {
                    Task { await loadData(resetOffset: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingData)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func filterTextField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("usageStats.summary.title".localized(), systemImage: "chart.bar.xaxis")

            if isLoadingData && summary == nil {
                loadingRow("usageStats.loading".localized())
            } else if let summary {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    KPICard(
                        title: "usageStats.summary.requests".localized(),
                        value: summary.totalRequests.formatted(),
                        subtitle: "usageStats.summary.requests.subtitle".localized(),
                        icon: "number",
                        color: .blue
                    )
                    KPICard(
                        title: "usageStats.summary.success".localized(),
                        value: summary.successCount.formatted(),
                        subtitle: String(format: "usageStats.summary.errorsFormat".localized(), summary.failureCount),
                        icon: "checkmark.circle",
                        color: .green
                    )
                    KPICard(
                        title: "usageStats.summary.totalTokens".localized(),
                        value: formatCompact(summary.tokens.totalTokens),
                        subtitle: "usageStats.summary.totalTokens.subtitle".localized(),
                        icon: "text.word.spacing",
                        color: .purple
                    )
                    KPICard(
                        title: "usageStats.summary.promptTokens".localized(),
                        value: formatCompact(summary.tokens.promptTokens),
                        subtitle: "usageStats.summary.promptTokens.subtitle".localized(),
                        icon: "arrow.down.left.circle",
                        color: .indigo
                    )
                    KPICard(
                        title: "usageStats.summary.completionTokens".localized(),
                        value: formatCompact(summary.tokens.completionTokens),
                        subtitle: "usageStats.summary.completionTokens.subtitle".localized(),
                        icon: "arrow.up.right.circle",
                        color: .teal
                    )
                    KPICard(
                        title: "usageStats.summary.cost".localized(),
                        value: formatCost(summary.estimatedCostUSD),
                        subtitle: averageLatencySubtitle(summary),
                        icon: "dollarsign.circle",
                        color: .orange
                    )
                }
            } else {
                ContentUnavailableView {
                    Label("usageStats.summary.empty.title".localized(), systemImage: "chart.bar")
                } description: {
                    Text("usageStats.summary.empty.description".localized())
                }
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("usageStats.events.title".localized(), systemImage: "list.bullet.rectangle")
                Spacer()
                paginationControls
            }

            UsageEventsTable(
                events: events,
                isLoading: isLoadingData,
                onReload: {
                    Task { await loadData(resetOffset: false) }
                }
            )
        }
    }

    private var paginationControls: some View {
        HStack(spacing: 8) {
            Button {
                offset = max(0, offset - selectedLimit)
                Task { await loadData(resetOffset: false) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("usageStats.pagination.previous".localized())
            .disabled(offset == 0 || isLoadingData)

            Text(String(format: "usageStats.pagination.offsetFormat".localized(), offset))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                offset += selectedLimit
                Task { await loadData(resetOffset: false) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("usageStats.pagination.next".localized())
            .disabled(events.count < selectedLimit || isLoadingData)
        }
    }

    private var costEstimationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("usageStats.cost.title".localized(), systemImage: "dollarsign.circle")
                Spacer()
                Button {
                    Task { await syncModelPrices() }
                } label: {
                    Label("usageStats.cost.sync".localized(), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(isSyncingPrices)
            }

            Text("usageStats.cost.description".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                CostEstimationMetric(
                    title: "usageStats.cost.priceCount".localized(),
                    value: modelPriceCountText,
                    systemImage: "tablecells"
                )
                CostEstimationMetric(
                    title: "usageStats.cost.lastSync".localized(),
                    value: modelPriceLastSyncText,
                    systemImage: "clock.arrow.circlepath"
                )
                CostEstimationMetric(
                    title: "usageStats.cost.state".localized(),
                    value: modelPriceStateText,
                    systemImage: modelPriceStateIcon
                )
            }

            if isSyncingPrices {
                loadingRow("usageStats.cost.syncing".localized())
            } else if let pricesError {
                errorSection(pricesError) {
                    Task { await syncModelPrices() }
                }
            } else if let syncError = status?.modelPricesSyncError, !syncError.isEmpty {
                UsageStatsMessageRow(
                    title: "usageStats.cost.syncError.title".localized(),
                    message: syncError,
                    actionTitle: "usageStats.cost.sync".localized(),
                    onAction: {
                        Task { await syncModelPrices() }
                    }
                )
            }

            if let syncResult {
                syncResultView(syncResult)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var isDisabledState: Bool {
        if let status, !status.enabled { return true }
        if let dataError, isUsageStatsDisabledMessage(dataError) { return true }
        return false
    }

    private var modelPriceCountText: String {
        guard let count = status?.modelPricesCount else { return "-" }
        return count.formatted()
    }

    private var modelPriceLastSyncText: String {
        guard let timestamp = status?.modelPricesLastSyncedAtMS, timestamp > 0 else {
            return "usageStats.cost.neverSynced".localized()
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private var modelPriceStateText: String {
        if isSyncingPrices || status?.modelPricesSyncing == true {
            return "usageStats.cost.state.syncing".localized()
        }
        if pricesError != nil || !(status?.modelPricesSyncError ?? "").isEmpty {
            return "usageStats.cost.state.error".localized()
        }
        guard let count = status?.modelPricesCount else {
            return "usageStats.cost.state.unknown".localized()
        }
        return count > 0 ? "usageStats.cost.state.ready".localized() : "usageStats.cost.state.pending".localized()
    }

    private var modelPriceStateIcon: String {
        if isSyncingPrices || status?.modelPricesSyncing == true {
            return "arrow.triangle.2.circlepath"
        }
        if pricesError != nil || !(status?.modelPricesSyncError ?? "").isEmpty {
            return "exclamationmark.triangle"
        }
        guard let count = status?.modelPricesCount else {
            return "questionmark.circle"
        }
        return count > 0 ? "checkmark.circle" : "clock"
    }

    private var isUnsupportedState: Bool {
        dataError == "usageStats.unsupported.description".localized()
    }

    private var currentFilter: UsageStatsFilter {
        var filter = UsageStatsFilter()
        filter.account = accountFilter
        filter.model = modelFilter
        filter.channel = channelFilter
        filter.authIndex = authIndexFilter
        if useStartDate {
            filter.startMS = Int64(startDate.timeIntervalSince1970 * 1000)
        }
        if useEndDate {
            filter.endMS = Int64(endDate.timeIntervalSince1970 * 1000)
        }
        return filter
    }

    private var disabledStateView: some View {
        ContentUnavailableView {
            Label("usageStats.disabled.title".localized(), systemImage: "chart.xyaxis.line")
        } description: {
            Text("usageStats.disabled.description".localized())
        } actions: {
            Button("action.retry".localized()) {
                Task { await loadAll(resetOffset: false) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private func errorSection(_ message: String, retry: @escaping () -> Void) -> some View {
        UsageStatsMessageRow(
            title: "usageStats.error.title".localized(),
            message: message,
            actionTitle: "action.retry".localized(),
            onAction: retry
        )
    }

    private func syncResultView(_ result: UsageStatsModelPricesSyncResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("usageStats.cost.syncResult.title".localized())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(String(format: "usageStats.cost.syncResult.summary".localized(), result.source, result.imported, result.skipped))
                .font(.caption)
            if let unmatched = result.unmatched, !unmatched.isEmpty {
                Text(String(format: "usageStats.cost.syncResult.unmatched".localized(), unmatched.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @MainActor
    private func loadAll(resetOffset: Bool) async {
        await loadData(resetOffset: resetOffset)
    }

    @MainActor
    private func loadData(resetOffset: Bool) async {
        guard let client = viewModel.apiClient else { return }
        if resetOffset {
            offset = 0
        }

        isLoadingData = true
        dataError = nil
        defer { isLoadingData = false }

        do {
            let fetchedStatus = try await client.fetchUsageStatsStatus()
            status = fetchedStatus
            guard fetchedStatus.enabled && fetchedStatus.open else {
                summary = nil
                events = []
                return
            }

            async let summaryTask = client.fetchUsageStatsSummary(filter: currentFilter, includeCost: true)
            async let eventsTask = client.fetchUsageStatsEvents(filter: currentFilter, limit: selectedLimit, offset: offset)
            let (fetchedSummary, fetchedEvents) = try await (summaryTask, eventsTask)
            summary = fetchedSummary
            events = fetchedEvents.events
        } catch {
            summary = nil
            events = []
            dataError = usageStatsErrorMessage(error)
        }
    }

    @MainActor
    private func syncModelPrices() async {
        guard let client = viewModel.apiClient else { return }

        isSyncingPrices = true
        pricesError = nil
        syncResult = nil
        defer { isSyncingPrices = false }

        do {
            let result = try await client.syncUsageStatsModelPrices(includePrices: false)
            syncResult = result
            await loadData(resetOffset: false)
        } catch {
            pricesError = usageStatsErrorMessage(error)
        }
    }

    private func resetFilters() {
        accountFilter = ""
        modelFilter = ""
        channelFilter = ""
        authIndexFilter = ""
        useStartDate = false
        useEndDate = false
        offset = 0
    }

    private func usageStatsErrorMessage(_ error: Error) -> String {
        if case APIError.httpError(404) = error {
            return "usageStats.unsupported.description".localized()
        }
        if case APIError.apiError(let statusCode, _, _) = error,
           statusCode == 404 {
            return "usageStats.unsupported.description".localized()
        }
        if case APIError.apiError(let statusCode, let code, let message) = error,
           statusCode == 503,
           code == "usage_stats_disabled" || code == "usage_stats_unavailable" {
            return message
        }
        return error.localizedDescription
    }

    private func isUsageStatsDisabledMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("usage stats service is disabled")
            || message.localizedCaseInsensitiveContains("usage stats service is unavailable")
    }

    private func formatCompact(_ value: Int64) -> String {
        let doubleValue = Double(value)
        if value >= 1_000_000 {
            return String(format: "%.1fM", doubleValue / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", doubleValue / 1_000)
        }
        return value.formatted()
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "$%.4f", value)
    }

    private func averageLatencySubtitle(_ summary: UsageStatsSummary) -> String {
        guard let average = summary.averageLatencyMS else {
            return "usageStats.summary.cost.subtitle".localized()
        }
        return String(format: "usageStats.summary.avgLatencyFormat".localized(), average)
    }
}

private enum UsageEventsTableMetrics {
    static let timeWidth: CGFloat = 138
    static let accountWidth: CGFloat = 170
    static let modelWidth: CGFloat = 230
    static let channelWidth: CGFloat = 120
    static let latencyWidth: CGFloat = 90
    static let statusWidth: CGFloat = 82
    static let tokenWidth: CGFloat = 92
    static let costWidth: CGFloat = 100
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 12
}

private struct UsageEventsTable: View {
    let events: [UsageStatsEvent]
    let isLoading: Bool
    var onReload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    UsageEventsTableHeader()
                    Divider()
                    tableContent
                }
                .frame(minWidth: 1120, alignment: .leading)
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

    @ViewBuilder
    private var tableContent: some View {
        if isLoading && events.isEmpty {
            UsageStatsLoadingRow()
        } else if events.isEmpty {
            UsageStatsMessageRow(
                title: "usageStats.events.empty.title".localized(),
                message: "usageStats.events.empty.description".localized(),
                actionTitle: "action.refresh".localized(),
                onAction: onReload
            )
        } else {
            ForEach(events) { event in
                UsageEventRow(event: event)
                if event.id != events.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct UsageEventsTableHeader: View {
    var body: some View {
        UsageEventsGrid {
            header("usageStats.events.columns.time".localized(), width: UsageEventsTableMetrics.timeWidth)
            header("usageStats.events.columns.account".localized(), width: UsageEventsTableMetrics.accountWidth)
            header("usageStats.events.columns.model".localized(), width: UsageEventsTableMetrics.modelWidth)
            header("usageStats.events.columns.channel".localized(), width: UsageEventsTableMetrics.channelWidth)
            header("usageStats.events.columns.latency".localized(), width: UsageEventsTableMetrics.latencyWidth, alignment: .trailing)
            header("usageStats.events.columns.status".localized(), width: UsageEventsTableMetrics.statusWidth, alignment: .trailing)
            header("usageStats.events.columns.prompt".localized(), width: UsageEventsTableMetrics.tokenWidth, alignment: .trailing)
            header("usageStats.events.columns.completion".localized(), width: UsageEventsTableMetrics.tokenWidth, alignment: .trailing)
            header("usageStats.events.columns.total".localized(), width: UsageEventsTableMetrics.tokenWidth, alignment: .trailing)
            header("usageStats.events.columns.cost".localized(), width: UsageEventsTableMetrics.costWidth, alignment: .trailing)
        }
        .frame(height: 34)
    }

    private func header(_ title: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

private struct UsageEventRow: View {
    let event: UsageStatsEvent

    var body: some View {
        UsageEventsGrid {
            Text(event.timestampDate.formatted(date: .numeric, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: UsageEventsTableMetrics.timeWidth, alignment: .leading)

            textColumn(event.displayAccount, width: UsageEventsTableMetrics.accountWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayModel)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if event.displaySourceModel != event.displayModel {
                    Text(event.displaySourceModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: UsageEventsTableMetrics.modelWidth, alignment: .leading)

            textColumn(event.displayChannel, width: UsageEventsTableMetrics.channelWidth)
            numericColumn(event.latencyMS.map { "\($0) ms" } ?? "-", width: UsageEventsTableMetrics.latencyWidth)
            statusBadge
                .frame(width: UsageEventsTableMetrics.statusWidth, alignment: .trailing)
            numericColumn(event.promptTokens.formatted(), width: UsageEventsTableMetrics.tokenWidth)
            numericColumn(event.completionTokens.formatted(), width: UsageEventsTableMetrics.tokenWidth)
            numericColumn(event.totalTokens.formatted(), width: UsageEventsTableMetrics.tokenWidth)
            numericColumn(formatCost(event.estimatedCostUSD), width: UsageEventsTableMetrics.costWidth)
        }
        .frame(minHeight: 48)
    }

    private var statusBadge: some View {
        Text(event.statusCode > 0 ? "\(event.statusCode)" : "-")
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var statusColor: Color {
        if event.failed { return .red }
        switch event.statusCode {
        case 200..<300: return .green
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .gray
        }
    }

    private func textColumn(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
    }

    private func numericColumn(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "$%.4f", value)
    }
}

private struct UsageEventsGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: UsageEventsTableMetrics.spacing) {
            content
        }
        .padding(.horizontal, UsageEventsTableMetrics.horizontalPadding)
    }
}

private struct UsageStatsLoadingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("usageStats.loading".localized())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .center)
    }
}

private struct UsageStatsMessageRow: View {
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

private struct CostEstimationMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusBadge: View {
    let status: UsageStatsStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .help(status.path ?? "")
    }

    private var title: String {
        guard status.enabled else { return "usageStats.status.disabled".localized() }
        return status.open ? "usageStats.status.active".localized() : "usageStats.status.closed".localized()
    }

    private var color: Color {
        guard status.enabled else { return .secondary }
        return status.open ? .green : .orange
    }
}
