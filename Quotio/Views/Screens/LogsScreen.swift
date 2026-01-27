//
//  LogsScreen.swift
//  Quotio
//

import SwiftUI

struct LogsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(LogsViewModel.self) private var logsViewModel
    @State private var selectedTab: LogsTab = .requests
    @State private var autoScroll = true
    @State private var filterLevel: LogEntry.LogLevel? = nil
    @State private var searchText = ""
    @State private var requestFilterProvider: String? = nil
    @State private var expandedTraces: Set<UUID> = []
    
    enum LogsTab: String, CaseIterable {
        case requests = "requests"
        case proxyLogs = "proxyLogs"
        
        var title: String {
            switch self {
            case .requests: return "logs.tab.requests".localizedStatic()
            case .proxyLogs: return "logs.tab.proxyLogs".localizedStatic()
            }
        }
        
        var icon: String {
            switch self {
            case .requests: return "arrow.up.arrow.down"
            case .proxyLogs: return "doc.text"
            }
        }
    }
    
    var body: some View {
        Group {
            if !viewModel.proxyManager.proxyStatus.running {
                ProxyRequiredView(
                    description: "logs.startProxy".localized()
                ) {
                    await viewModel.startProxy()
                }
            } else {
                VStack(spacing: 0) {
                    // Tab Picker
                    Picker("Tab", selection: $selectedTab) {
                        ForEach(LogsTab.allCases, id: \.self) { tab in
                            Label(tab.title, systemImage: tab.icon)
                                .tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    
                    Divider()
                    
                    // Tab Content
                    switch selectedTab {
                    case .requests:
                        requestHistoryView
                    case .proxyLogs:
                        proxyLogsView
                    }
                }
            }
        }
        .navigationTitle("nav.logs".localized())
        .searchable(text: $searchText, prompt: searchPrompt)
        .toolbar {
            toolbarContent
        }
        .task {
            // Configure LogsViewModel with proxy connection when screen appears
            if !logsViewModel.isConfigured {
                logsViewModel.configure(
                    baseURL: viewModel.proxyManager.managementURL,
                    authKey: viewModel.proxyManager.managementKey
                )
            }
            
            while !Task.isCancelled {
                if selectedTab == .proxyLogs {
                    await logsViewModel.refreshLogs()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    
    private var searchPrompt: String {
        switch selectedTab {
        case .requests:
            return "logs.searchRequests".localized()
        case .proxyLogs:
            return "logs.searchLogs".localized()
        }
    }
    
    // MARK: - Request History View
    
    private var requestHistoryView: some View {
        Group {
            if viewModel.requestTracker.requestHistory.isEmpty {
                ContentUnavailableView {
                    Label("logs.noRequests".localized(), systemImage: "arrow.up.arrow.down")
                } description: {
                    Text("logs.requestsWillAppear".localized())
                }
            } else {
                VStack(spacing: 0) {
                    // Stats Header
                    requestStatsHeader
                    
                    Divider()
                    
                    // Request List
                    requestList
                }
            }
        }
    }
    
    private var requestStatsHeader: some View {
        let stats = viewModel.requestTracker.stats
        
        return HStack(spacing: 24) {
            StatItem(
                title: "logs.stats.totalRequests".localized(),
                value: "\(stats.totalRequests)"
            )
            
            StatItem(
                title: "logs.stats.successRate".localized(),
                value: String(format: "%.0f%%", stats.successRate)
            )
            
            StatItem(
                title: "logs.stats.totalTokens".localized(),
                value: stats.totalTokens.formattedTokenCount
            )
            
            StatItem(
                title: "logs.stats.avgDuration".localized(),
                value: "\(stats.averageDurationMs)ms"
            )
            
            Spacer()
            
            // Provider Filter
            Picker("Provider", selection: $requestFilterProvider) {
                Text("logs.filter.allProviders".localized()).tag(nil as String?)
                Divider()
                ForEach(Array(stats.byProvider.keys.sorted()), id: \.self) { provider in
                    Text(provider.capitalized).tag(provider as String?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        .padding()
        .background(.regularMaterial)
    }
    
    private var filteredRequests: [RequestLog] {
        var requests = viewModel.requestTracker.requestHistory
        
        if let provider = requestFilterProvider {
            requests = requests.filter { $0.provider == provider }
        }
        
        if !searchText.isEmpty {
            requests = requests.filter {
                ($0.provider?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.model?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.endpoint.localizedCaseInsensitiveContains(searchText))
            }
        }
        
        return requests
    }
    
    private var requestList: some View {
        ScrollViewReader { proxy in
            List(filteredRequests) { request in
                RequestRow(
                    request: request,
                    isTraceExpanded: expandedTraces.contains(request.id),
                    onToggleTrace: {
                        if expandedTraces.contains(request.id) {
                            expandedTraces.remove(request.id)
                        } else {
                            expandedTraces.insert(request.id)
                        }
                    }
                )
                .id("\(request.id)-\(expandedTraces.contains(request.id))")
            }
            .onChange(of: viewModel.requestTracker.requestHistory.count) { _, _ in
                if autoScroll, let first = filteredRequests.first {
                    withAnimation {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
    }
    
    // MARK: - Proxy Logs View
    
    var filteredLogs: [LogEntry] {
        var logs = logsViewModel.logs
        
        if let level = filterLevel {
            logs = logs.filter { $0.level == level }
        }
        
        if !searchText.isEmpty {
            logs = logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
        
        return logs
    }
    
    private var proxyLogsView: some View {
        Group {
            if filteredLogs.isEmpty {
                ContentUnavailableView {
                    Label("logs.noLogs".localized(), systemImage: "doc.text")
                } description: {
                    Text("logs.logsWillAppear".localized())
                }
            } else {
                logList
            }
        }
    }
    
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredLogs) { entry in
                LogRow(entry: entry)
                    .id(entry.id)
            }
            .onChange(of: logsViewModel.logs.count) { _, _ in
                if autoScroll, let last = filteredLogs.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if selectedTab == .proxyLogs {
                Picker("Filter", selection: $filterLevel) {
                    Text("logs.all".localized()).tag(nil as LogEntry.LogLevel?)
                    Divider()
                    Text("logs.info".localized()).tag(LogEntry.LogLevel.info as LogEntry.LogLevel?)
                    Text("logs.warn".localized()).tag(LogEntry.LogLevel.warn as LogEntry.LogLevel?)
                    Text("logs.error".localized()).tag(LogEntry.LogLevel.error as LogEntry.LogLevel?)
                }
                .pickerStyle(.menu)
            }
            
            Toggle(isOn: $autoScroll) {
                Label("logs.autoScroll".localized(), systemImage: "arrow.down.to.line")
            }
            
            Button {
                if selectedTab == .requests {
                    // Refresh handled by RequestTracker automatically
                } else {
                    Task { await logsViewModel.refreshLogs() }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            
            Button(role: .destructive) {
                if selectedTab == .requests {
                    viewModel.requestTracker.clearHistory()
                } else {
                    Task { await logsViewModel.clearLogs() }
                }
            } label: {
                Image(systemName: "trash")
            }
        }
    }
}

// MARK: - Request Row

struct RequestRow: View {
    let request: RequestLog
    let isTraceExpanded: Bool
    let onToggleTrace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                // Timestamp
                Text(request.formattedTimestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)

                // Status Badge
                statusBadge

                // Provider & Model with Fallback Route
                VStack(alignment: .leading, spacing: 2) {
                    if request.hasFallbackRoute {
                        // Show fallback route: virtual model → resolved model
                        HStack(spacing: 4) {
                            Text(request.model ?? "unknown")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.orange)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(request.resolvedProvider?.capitalized ?? "")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.blue)
                        }
                        Text(request.resolvedModel ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        // Normal display
                        if let provider = request.provider {
                            Text(provider.capitalized)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        if let model = request.model {
                            Text(model)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: 180, alignment: .leading)

                // Tokens
                if let tokens = request.formattedTokens {
                    HStack(spacing: 4) {
                        Image(systemName: "text.word.spacing")
                            .font(.caption2)
                        Text(tokens)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                } else {
                    Text("-")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .trailing)
                }

                // Duration
                Text(request.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)

                Spacer()

                // Size
                HStack(spacing: 4) {
                    Text("\(request.requestSize.formatted())B")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(request.responseSize.formatted())B")
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
            }

            if let attempts = request.fallbackAttempts, !attempts.isEmpty {
                Button {
                    onToggleTrace()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isTraceExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("logs.fallbackTrace".localized())
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isTraceExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
                            HStack(spacing: 6) {
                                Text("\(index + 1).")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, alignment: .trailing)

                                Text("\(attempt.provider) → \(attempt.modelId)")
                                    .font(.caption2)
                                    .lineLimit(1)

                                Text(attemptOutcomeLabel(attempt.outcome))
                                    .font(.caption2)
                                    .foregroundStyle(attemptOutcomeColor(attempt.outcome))

                                if let reason = attempt.reason {
                                    Text(reason.displayValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let errorMessage = request.errorMessage, !errorMessage.isEmpty {
                            HStack(spacing: 6) {
                                Text("logs.fallbackBackendResponse".localized())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(errorMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(request.statusBadge)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var statusColor: Color {
        guard let code = request.statusCode else { return .gray }
        switch code {
        case 200..<300: return .green
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .gray
        }
    }

    private func attemptOutcomeLabel(_ outcome: FallbackAttemptOutcome) -> String {
        switch outcome {
        case .failed:
            return "logs.fallbackAttempt.failed".localized()
        case .success:
            return "logs.fallbackAttempt.success".localized()
        case .skipped:
            return "logs.fallbackAttempt.skipped".localized()
        }
    }

    private func attemptOutcomeColor(_ outcome: FallbackAttemptOutcome) -> Color {
        switch outcome {
        case .failed:
            return .orange
        case .success:
            return .green
        case .skipped:
            return .secondary
        }
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
        }
    }
}

// MARK: - Log Row

struct LogRow: View {
    let entry: LogEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            
            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(entry.level.color)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
