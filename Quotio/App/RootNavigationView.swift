import QuotioPresentation
import SwiftUI

struct RootNavigationView: View {
    let logsScreenModel: LogsScreenModel

    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(OperatingModeManager.self) private var modeManager
    @AppStorage("loggingToFile") private var loggingToFile = true

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $viewModel.currentPage) {
                    Section {
                        Label("nav.dashboard".localized(), systemImage: "gauge.with.dots.needle.33percent")
                            .tag(NavigationPage.dashboard)

                        Label("nav.quota".localized(), systemImage: "chart.bar.fill")
                            .tag(NavigationPage.quota)

                        Label(
                            modeManager.isMonitorMode ? "nav.accounts".localized() : "nav.providers".localized(),
                            systemImage: "person.2.badge.key"
                        )
                        .tag(NavigationPage.providers)

                        if modeManager.isLocalProxyMode {
                            Label("nav.agents".localized(), systemImage: "terminal")
                                .tag(NavigationPage.agents)

                            Label("nav.apiKeys".localized(), systemImage: "key.horizontal")
                                .tag(NavigationPage.apiKeys)

                            if loggingToFile {
                                Label("nav.logs".localized(), systemImage: "doc.text")
                                    .tag(NavigationPage.logs)
                            }
                        }

                        Label("nav.settings".localized(), systemImage: "gearshape")
                            .tag(NavigationPage.settings)

                        Label("nav.about".localized(), systemImage: "info.circle")
                            .tag(NavigationPage.about)
                    }
                }

                VStack(spacing: 0) {
                    Divider()

                    CurrentModeBadge()
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    Group {
                        if modeManager.isLocalProxyMode {
                            ProxyStatusRow(viewModel: viewModel)
                        } else {
                            QuotaRefreshStatusRow(viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .background(.regularMaterial)
            }
            .navigationTitle("Quotio")
            .toolbar {
                ToolbarItem {
                    if modeManager.isLocalProxyMode {
                        if viewModel.proxyManager.isStarting {
                            SmallProgressView()
                        } else {
                            Button {
                                Task { await viewModel.toggleProxy() }
                            } label: {
                                Image(
                                    systemName: viewModel.proxyManager.proxyStatus.running
                                        ? "stop.fill"
                                        : "play.fill"
                                )
                            }
                            .help(
                                viewModel.proxyManager.proxyStatus.running
                                    ? "action.stopProxy".localized()
                                    : "action.startProxy".localized()
                            )
                        }
                    } else {
                        Button {
                            Task { await viewModel.manualRefresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("action.refreshQuota".localized())
                        .disabled(viewModel.isLoadingQuotas)
                    }
                }
            }
        } detail: {
            switch viewModel.currentPage {
            case .dashboard:
                DashboardScreen()
            case .quota:
                QuotaScreen()
            case .providers:
                ProvidersScreen()
            case .agents:
                AgentSetupScreen()
            case .apiKeys:
                APIKeysScreen()
            case .logs:
                if viewModel.proxyManager.proxyStatus.running {
                    QuotioPresentation.LogsScreen(model: logsScreenModel)
                } else {
                    ProxyRequiredView(
                        description: "logs.startProxy".localized()
                    ) {
                        await viewModel.startProxy()
                    }
                    .navigationTitle("nav.logs".localized())
                }
            case .settings:
                SettingsScreen()
            case .about:
                AboutScreen()
            }
        }
    }
}

struct ProxyStatusRow: View {
    let viewModel: QuotaViewModel

    var body: some View {
        HStack {
            if viewModel.proxyManager.isStarting {
                SmallProgressView(size: 8)
            } else {
                Circle()
                    .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                    .frame(width: 8, height: 8)
            }

            Text(
                viewModel.proxyManager.isStarting
                    ? "status.starting".localized()
                    : viewModel.proxyManager.proxyStatus.running
                        ? "status.running".localized()
                        : "status.stopped".localized()
            )
            .font(.caption)

            Spacer()

            Text(":" + String(viewModel.proxyManager.port))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct QuotaRefreshStatusRow: View {
    let viewModel: QuotaViewModel

    var body: some View {
        HStack {
            if viewModel.isLoadingQuotas {
                SmallProgressView(size: 8)
                Text("status.refreshing".localized())
                    .font(.caption)
            } else {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let lastRefresh = viewModel.lastQuotaRefreshTime {
                    Text("status.updatedAgo \(lastRefresh, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("status.notRefreshed".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }
}
