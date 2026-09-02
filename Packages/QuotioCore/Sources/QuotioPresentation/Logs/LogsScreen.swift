import QuotioDomain
import SwiftUI

public struct LogsScreen: View {
    @Bindable private var model: LogsScreenModel
    @State private var autoScroll = true
    @State private var filterLevel: LogEntry.Level?
    @State private var searchText = ""

    public init(model: LogsScreenModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage, !model.entries.isEmpty {
                errorBanner(errorMessage)
            }
            content
        }
        .navigationTitle(Text("nav.logs"))
        .searchable(text: $searchText, prompt: Text("logs.searchLogs"))
        .toolbar {
            toolbarContent
        }
        .task {
            await model.poll()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView {
                Label("logs.error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("action.retry") {
                    Task { await model.refresh() }
                }
            }
        case .empty, .content:
            if filteredLogs.isEmpty {
                emptyView
            } else {
                logList
            }
        }
    }

    private var filteredLogs: [LogEntry] {
        model.entries.filter { entry in
            let includesLevel = filterLevel.map { entry.level == $0 } ?? true
            let includesSearch = searchText.isEmpty
                || entry.message.localizedCaseInsensitiveContains(searchText)
            return includesLevel && includesSearch
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("logs.noLogs", systemImage: "doc.text")
        } description: {
            Text("logs.logsWillAppear")
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredLogs) { entry in
                LogRow(entry: entry)
                    .id(entry.id)
            }
            .onChange(of: model.entries.count) { _, _ in
                if autoScroll, let last = filteredLogs.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Filter", selection: $filterLevel) {
                Text("logs.all").tag(nil as LogEntry.Level?)
                Divider()
                Text("logs.info").tag(LogEntry.Level.info as LogEntry.Level?)
                Text("logs.warn").tag(LogEntry.Level.warn as LogEntry.Level?)
                Text("logs.error").tag(LogEntry.Level.error as LogEntry.Level?)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $autoScroll) {
                Label("logs.autoScroll", systemImage: "arrow.down.to.line")
            }

            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshing || model.isClearing)

            Button(role: .destructive) {
                Task { await model.clear() }
            } label: {
                if model.isClearing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
            }
            .disabled(model.isRefreshing || model.isClearing)
        }
    }
}

private struct LogRow: View {
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

private extension LogEntry.Level {
    var color: Color {
        switch self {
        case .info:
            .primary
        case .warn:
            .orange
        case .error:
            .red
        case .debug:
            .gray
        }
    }
}
