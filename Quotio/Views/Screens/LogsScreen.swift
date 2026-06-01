//
//  LogsScreen.swift
//  Quotio
//

import AppKit
import SwiftUI

struct LogsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = OperatingModeManager.shared
    @State private var selectedTab: LogsTab = .application
    @State private var loggingToFile: Bool?
    @State private var requestLogEnabled: Bool?
    @State private var logLines: [String] = []
    @State private var lineCount = 0
    @State private var latestTimestamp: Int?
    @State private var selectedLimit = 250
    @State private var isLoadingApplicationLogs = false
    @State private var applicationLogsError: String?
    @State private var isUpdatingLoggingToggle = false
    @State private var showClearConfirmation = false

    @State private var requestErrorLogFiles: [RequestErrorLogFile] = []
    @State private var requestID = ""
    @State private var debugLogTitle: String?
    @State private var debugLogContent: String?
    @State private var debugLogData: Data?
    @State private var isLoadingDebugLogs = false
    @State private var debugLogsError: String?
    @State private var isUpdatingRequestLogToggle = false

    private let limitOptions = [100, 250, 500, 1000]

    enum LogsTab: String, CaseIterable {
        case application
        case rawDebug

        var title: String {
            switch self {
            case .application: return "logs.tab.application".localizedStatic()
            case .rawDebug: return "logs.tab.rawDebug".localizedStatic()
            }
        }

        var icon: String {
            switch self {
            case .application: return "doc.text"
            case .rawDebug: return "ladybug"
            }
        }
    }

    var body: some View {
        Group {
            if modeManager.isLocalProxyMode && !viewModel.proxyManager.proxyStatus.running {
                ProxyRequiredView(description: "logs.startProxy".localized()) {
                    await viewModel.ensureProxyRunning()
                }
            } else if viewModel.apiClient == nil {
                ContentUnavailableView {
                    Label("logs.managementUnavailable.title".localized(), systemImage: "network.slash")
                } description: {
                    Text("logs.managementUnavailable.description".localized())
                } actions: {
                    Button("action.retry".localized()) {
                        Task { await viewModel.initialize() }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("logs.tabPicker".localized())
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("logs.tabPicker".localized(), selection: $selectedTab) {
                            ForEach(LogsTab.allCases, id: \.self) { tab in
                                Label(tab.title, systemImage: tab.icon)
                                    .tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 420)

                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)

                    Divider()

                    switch selectedTab {
                    case .application:
                        applicationLogsView
                    case .rawDebug:
                        rawDebugLogsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle("nav.logs".localized())
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await loadSelectedTab() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("action.refresh".localized())
                .disabled(isLoadingApplicationLogs || isLoadingDebugLogs || viewModel.apiClient == nil)

                if selectedTab == .application {
                    Button {
                        Task { await loadNewApplicationLogs() }
                    } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                    .help("logs.loadNew".localized())
                    .disabled(isLoadingApplicationLogs || latestTimestamp == nil || loggingToFile == false)

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("logs.clear".localized())
                    .disabled(isLoadingApplicationLogs || loggingToFile == false)
                }
            }
        }
        .task {
            await loadInitialState()
        }
        .onChange(of: selectedTab) {
            Task { await loadSelectedTab() }
        }
        .onChange(of: selectedLimit) {
            Task { await loadApplicationLogs(loadNewOnly: false) }
        }
        .confirmationDialog(
            "logs.clear.confirmTitle".localized(),
            isPresented: $showClearConfirmation
        ) {
            Button("logs.clear".localized(), role: .destructive) {
                Task { await clearApplicationLogs() }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("logs.clear.confirmMessage".localized())
        }
    }

    private var applicationLogsView: some View {
        VStack(spacing: 0) {
            applicationLogsHeader
            Divider()

            if isLoadingApplicationLogs && logLines.isEmpty {
                loadingView("logs.loading".localized())
            } else if loggingToFile == false {
                loggingDisabledView
            } else if let applicationLogsError {
                errorView(applicationLogsError) {
                    Task { await loadApplicationLogs(loadNewOnly: false) }
                }
            } else if logLines.isEmpty {
                ContentUnavailableView {
                    Label("logs.noLogs".localized(), systemImage: "doc.text")
                } description: {
                    Text("logs.application.emptyDescription".localized())
                }
            } else {
                logViewer(lines: logLines)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var applicationLogsHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("logs.application.title".localized())
                    .font(.headline)
                Text("logs.application.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatItem(title: "logs.lineCount".localized(), value: "\(lineCount)")

            Picker("logs.limit".localized(), selection: $selectedLimit) {
                ForEach(limitOptions, id: \.self) { limit in
                    Text("\(limit)").tag(limit)
                }
            }
            .frame(width: 120)
            .disabled(loggingToFile == false)

            Toggle("logs.loggingToFile".localized(), isOn: loggingToFileBinding)
                .disabled(isUpdatingLoggingToggle)
        }
        .padding()
        .background(.regularMaterial)
    }

    private var loggingDisabledView: some View {
        ContentUnavailableView {
            Label("logs.disabled.title".localized(), systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("logs.disabled.description".localized())
        } actions: {
            Button("logs.enableLogging".localized()) {
                Task { await setLoggingToFile(true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUpdatingLoggingToggle)
        }
    }

    private var rawDebugLogsView: some View {
        VStack(spacing: 0) {
            rawDebugHeader
            Divider()

            if isLoadingDebugLogs && requestErrorLogFiles.isEmpty && debugLogContent == nil {
                loadingView("logs.debug.loading".localized())
            } else if let debugLogsError {
                errorView(debugLogsError) {
                    Task { await loadRawDebugState() }
                }
            } else {
                HStack(spacing: 0) {
                    requestErrorLogList
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                    Divider()
                    debugLogDetail
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rawDebugHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("logs.debug.title".localized())
                        .font(.headline)
                    Text("logs.debug.description".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("logs.debug.requestLog".localized(), isOn: requestLogBinding)
                    .disabled(isUpdatingRequestLogToggle)
            }

            HStack(spacing: 8) {
                TextField("logs.debug.requestID.placeholder".localized(), text: $requestID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        Task { await loadDebugLogByRequestID() }
                    }

                Button {
                    Task { await loadDebugLogByRequestID() }
                } label: {
                    Label("logs.debug.openByID".localized(), systemImage: "magnifyingglass")
                }
                .disabled(requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private var requestErrorLogList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("logs.debug.errorFiles".localized())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(requestErrorLogFiles.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if requestErrorLogFiles.isEmpty {
                ContentUnavailableView {
                    Label("logs.debug.noFiles".localized(), systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("logs.debug.noFilesDescription".localized())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(requestErrorLogFiles) { file in
                    Button {
                        Task { await openRequestErrorLog(file) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(file.size.formatted()) B • \(file.modifiedDate.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var debugLogDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(debugLogTitle ?? "logs.debug.detailTitle".localized())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    copyDebugLog()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("action.copy".localized())
                .disabled((debugLogContent ?? "").isEmpty)

                Button {
                    saveDebugLog()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("action.saveAs".localized())
                .disabled(debugLogData == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let debugLogContent, !debugLogContent.isEmpty {
                logViewer(lines: debugLogContent.components(separatedBy: .newlines))
            } else {
                ContentUnavailableView {
                    Label("logs.debug.noSelection".localized(), systemImage: "doc.text")
                } description: {
                    Text("logs.debug.noSelectionDescription".localized())
                }
            }
        }
    }

    private var loggingToFileBinding: Binding<Bool> {
        Binding(
            get: { loggingToFile ?? false },
            set: { newValue in
                Task { await setLoggingToFile(newValue) }
            }
        )
    }

    private var requestLogBinding: Binding<Bool> {
        Binding(
            get: { requestLogEnabled ?? false },
            set: { newValue in
                Task { await setRequestLog(newValue) }
            }
        )
    }

    private func logViewer(lines: [String]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private func loadingView(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("logs.error.title".localized(), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("action.retry".localized(), action: retry)
        }
    }

    @MainActor
    private func loadInitialState() async {
        guard viewModel.apiClient != nil else { return }
        await loadLoggingToFile()
        await loadRequestLog()
        await loadSelectedTab()
    }

    @MainActor
    private func loadSelectedTab() async {
        switch selectedTab {
        case .application:
            await loadApplicationLogs(loadNewOnly: false)
        case .rawDebug:
            await loadRawDebugState()
        }
    }

    @MainActor
    private func loadLoggingToFile() async {
        guard let client = viewModel.apiClient else { return }
        do {
            loggingToFile = try await client.getLoggingToFile()
        } catch {
            applicationLogsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadRequestLog() async {
        guard let client = viewModel.apiClient else { return }
        do {
            requestLogEnabled = try await client.getRequestLog()
        } catch {
            debugLogsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadApplicationLogs(loadNewOnly: Bool) async {
        guard let client = viewModel.apiClient else { return }

        isLoadingApplicationLogs = true
        applicationLogsError = nil
        defer { isLoadingApplicationLogs = false }

        do {
            if loggingToFile == nil {
                loggingToFile = try await client.getLoggingToFile()
            }
            let response = try await client.fetchLogs(
                limit: selectedLimit,
                after: loadNewOnly ? latestTimestamp : nil
            )
            loggingToFile = true
            lineCount = response.lineCount
            latestTimestamp = response.latestTimestamp
            if loadNewOnly {
                logLines.append(contentsOf: response.lines)
                if logLines.count > selectedLimit {
                    logLines = Array(logLines.suffix(selectedLimit))
                }
            } else {
                logLines = response.lines
            }
        } catch {
            if isLoggingDisabled(error) {
                loggingToFile = false
                logLines = []
                lineCount = 0
                latestTimestamp = nil
            } else {
                applicationLogsError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadNewApplicationLogs() async {
        await loadApplicationLogs(loadNewOnly: true)
    }

    @MainActor
    private func clearApplicationLogs() async {
        guard let client = viewModel.apiClient else { return }

        isLoadingApplicationLogs = true
        applicationLogsError = nil
        defer { isLoadingApplicationLogs = false }

        do {
            try await client.clearLogs()
            logLines = []
            lineCount = 0
            latestTimestamp = nil
        } catch {
            if isLoggingDisabled(error) {
                loggingToFile = false
            } else {
                applicationLogsError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func setLoggingToFile(_ enabled: Bool) async {
        guard let client = viewModel.apiClient else { return }

        isUpdatingLoggingToggle = true
        applicationLogsError = nil
        defer { isUpdatingLoggingToggle = false }

        do {
            try await client.setLoggingToFile(enabled)
            loggingToFile = enabled
            if enabled {
                await loadApplicationLogs(loadNewOnly: false)
            } else {
                logLines = []
                lineCount = 0
                latestTimestamp = nil
            }
        } catch {
            applicationLogsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadRawDebugState() async {
        guard let client = viewModel.apiClient else { return }

        isLoadingDebugLogs = true
        debugLogsError = nil
        defer { isLoadingDebugLogs = false }

        do {
            async let requestLogTask = client.getRequestLog()
            async let filesTask = client.fetchRequestErrorLogs()
            let (enabled, files) = try await (requestLogTask, filesTask)
            requestLogEnabled = enabled
            requestErrorLogFiles = files
        } catch {
            debugLogsError = error.localizedDescription
        }
    }

    @MainActor
    private func setRequestLog(_ enabled: Bool) async {
        guard let client = viewModel.apiClient else { return }

        isUpdatingRequestLogToggle = true
        debugLogsError = nil
        defer { isUpdatingRequestLogToggle = false }

        do {
            try await client.setRequestLog(enabled)
            requestLogEnabled = enabled
            await loadRawDebugState()
        } catch {
            debugLogsError = error.localizedDescription
        }
    }

    @MainActor
    private func openRequestErrorLog(_ file: RequestErrorLogFile) async {
        guard let client = viewModel.apiClient else { return }
        do {
            let data = try await client.fetchRequestErrorLog(name: file.name)
            debugLogTitle = file.name
            debugLogData = data
            debugLogContent = String(data: data, encoding: .utf8) ?? "logs.debug.nonUTF8".localized()
        } catch {
            debugLogsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadDebugLogByRequestID() async {
        guard let client = viewModel.apiClient else { return }
        let cleanID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { return }

        do {
            let data = try await client.fetchRequestLogByID(cleanID)
            debugLogTitle = cleanID
            debugLogData = data
            debugLogContent = String(data: data, encoding: .utf8) ?? "logs.debug.nonUTF8".localized()
        } catch {
            debugLogsError = error.localizedDescription
        }
    }

    private func copyDebugLog() {
        guard let debugLogContent, !debugLogContent.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(debugLogContent, forType: .string)
    }

    @MainActor
    private func saveDebugLog() {
        guard let debugLogData else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = debugLogTitle ?? "request-log.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try debugLogData.write(to: url)
        } catch {
            debugLogsError = error.localizedDescription
        }
    }

    private func isLoggingDisabled(_ error: Error) -> Bool {
        if case APIError.apiError(let statusCode, let code, _) = error {
            return statusCode == 400 && code == "logging to file disabled"
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("logging to file disabled")
    }
}

private struct StatItem: View {
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
