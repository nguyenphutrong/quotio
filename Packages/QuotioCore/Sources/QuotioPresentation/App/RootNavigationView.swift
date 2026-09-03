import QuotioApplication
import QuotioDomain
import SwiftUI

public struct RootNavigationView: View {
    let logsScreenModel: LogsScreenModel

    public init(logsScreenModel: LogsScreenModel) {
        self.logsScreenModel = logsScreenModel
    }

    @Environment(NavigationScreenModel.self) private var navigation
    @Environment(ProxyManagementScreenModel.self) private var proxyManagement
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var quotaController
    @Environment(OperatingModeManager.self) private var modeManager
    @Environment(SettingsScreenModel.self) private var settingsModel

    public var body: some View {
        @Bindable var navigation = navigation

        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $navigation.currentPage) {
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

                            if settingsModel.proxyPreferences.loggingToFile {
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
                            ProxyStatusRow(proxyManagement: proxyManagement)
                        } else {
                            QuotaRefreshStatusRow(quota: quota)
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
                        if proxyManagement.proxy.isStarting {
                            SmallProgressView()
                        } else {
                            Button {
                                Task { await proxyManagement.toggleProxy() }
                            } label: {
                                Image(
                                    systemName: proxyManagement.proxy.proxyStatus.running
                                        ? "stop.fill"
                                        : "play.fill"
                                )
                            }
                            .help(
                                proxyManagement.proxy.proxyStatus.running
                                    ? "action.stopProxy".localized()
                                    : "action.startProxy".localized()
                            )
                        }
                    } else {
                        Button {
                            Task { await quotaController.refreshAll(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("action.refreshQuota".localized())
                        .disabled(quota.isLoadingQuotas)
                    }
                }
            }
        } detail: {
            switch navigation.currentPage {
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
                if proxyManagement.proxy.proxyStatus.running {
                    LogsScreen(model: logsScreenModel)
                } else {
                    ProxyRequiredView(
                        description: "logs.startProxy".localized()
                    ) {
                        await proxyManagement.startProxy()
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
    let proxyManagement: ProxyManagementScreenModel

    var body: some View {
        HStack {
            if proxyManagement.proxy.isStarting {
                SmallProgressView(size: 8)
            } else {
                Circle()
                    .fill(proxyManagement.proxy.proxyStatus.running ? .green : .gray)
                    .frame(width: 8, height: 8)
            }

            Text(
                proxyManagement.proxy.isStarting
                    ? "status.starting".localized()
                    : proxyManagement.proxy.proxyStatus.running
                        ? "status.running".localized()
                        : "status.stopped".localized()
            )
            .font(.caption)

            Spacer()

            Text(":" + String(proxyManagement.proxy.port))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct QuotaRefreshStatusRow: View {
    let quota: QuotaScreenModel

    var body: some View {
        HStack {
            if quota.isLoadingQuotas {
                SmallProgressView(size: 8)
                Text("status.refreshing".localized())
                    .font(.caption)
            } else {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let lastRefresh = quota.lastRefreshTime {
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
