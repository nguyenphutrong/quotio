//
//  LogsScreen.swift
//  Quotio
//

import SwiftUI

struct LogsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(LogsViewModel.self) private var logsViewModel
    @State private var autoScroll = true
    @State private var filterLevel: LogEntry.LogLevel? = nil
    @State private var searchText = ""

    var body: some View {
        Group {
            if !viewModel.proxyManager.proxyStatus.running {
                ProxyRequiredView(
                    description: "logs.startProxy".localized()
                ) {
                    await viewModel.startProxy()
                }
            } else {
                proxyLogsView
            }
        }
        .navigationTitle("nav.logs".localized())
        .searchable(text: $searchText, prompt: "logs.searchLogs".localized())
        .toolbar {
            toolbarContent
        }
        .task {
            if !logsViewModel.isConfigured {
                logsViewModel.configure(
                    baseURL: viewModel.proxyManager.managementURL,
                    authKey: viewModel.proxyManager.managementKey
                )
            }

            while !Task.isCancelled {
                await logsViewModel.refreshLogs()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var filteredLogs: [LogEntry] {
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Filter", selection: $filterLevel) {
                Text("logs.all".localized()).tag(nil as LogEntry.LogLevel?)
                Divider()
                Text("logs.info".localized()).tag(LogEntry.LogLevel.info as LogEntry.LogLevel?)
                Text("logs.warn".localized()).tag(LogEntry.LogLevel.warn as LogEntry.LogLevel?)
                Text("logs.error".localized()).tag(LogEntry.LogLevel.error as LogEntry.LogLevel?)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $autoScroll) {
                Label("logs.autoScroll".localized(), systemImage: "arrow.down.to.line")
            }

            Button {
                Task { await logsViewModel.refreshLogs() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }

            Button(role: .destructive) {
                Task { await logsViewModel.clearLogs() }
            } label: {
                Image(systemName: "trash")
            }
        }
    }
}

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
