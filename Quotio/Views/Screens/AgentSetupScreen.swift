//
//  AgentSetupScreen.swift
//  Quotio - Main agent setup screen
//

import SwiftUI

struct AgentSetupScreen: View {
    @Environment(QuotaViewModel.self) private var quotaViewModel
    @State private var selectedAgentForConfig: CLIAgent?
    @State private var sheetPresentationID = UUID()
    @State private var hasLoadedOnce = false
    
    private var viewModel: AgentSetupViewModel {
        quotaViewModel.agentSetupViewModel
    }
    
    private var sortedAgents: [AgentStatus] {
        viewModel.agentStatuses.sorted { status1, status2 in
            if status1.installed != status2.installed {
                return status1.installed
            }
            return status1.agent.displayName < status2.agent.displayName
        }
    }
    
    private var installedAgents: [AgentStatus] {
        sortedAgents.filter { $0.installed }
    }
    
    private var notInstalledAgents: [AgentStatus] {
        sortedAgents.filter { !$0.installed }
    }
    
    var body: some View {
        Group {
            agentListView
        }
        .navigationTitle("agents.title".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refreshAgentStatuses(forceRefresh: true) }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task {
            if !hasLoadedOnce {
                await viewModel.refreshAgentStatuses()
                hasLoadedOnce = true
            }
        }
        .sheet(item: $selectedAgentForConfig) { (agent: CLIAgent) in
            AgentConfigSheet(viewModel: viewModel, agent: agent)
                .id(sheetPresentationID)
                .onDisappear {
                    viewModel.dismissConfiguration()
                }
        }
    }
    
    private var agentListView: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                
                if !installedAgents.isEmpty {
                    installedSection
                }
                
                if !notInstalledAgents.isEmpty {
                    notInstalledSection
                }
            }
            .padding(20)
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("agents.subtitle".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                StatChip(
                    icon: "checkmark.circle.fill",
                    value: "\(installedAgents.count)",
                    label: "agents.installed".localized(),
                    color: .green
                )
                
                StatChip(
                    icon: "gearshape.fill",
                    value: "\(installedAgents.filter { $0.configured }.count)",
                    label: "agents.configured".localized(),
                    color: .blue
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
    
    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("agents.installed".localized())
                .font(.headline)
                .foregroundStyle(.primary)
            
            LazyVStack(spacing: 12) {
                ForEach(installedAgents) { status in
                    AgentCard(
                        status: status,
                        onConfigure: {
                            let apiKey = quotaViewModel.apiKeys.first ?? quotaViewModel.proxyManager.managementKey
                            viewModel.startConfiguration(for: status.agent, apiKey: apiKey)
                            sheetPresentationID = UUID()
                            selectedAgentForConfig = status.agent
                        }
                    )
                }
            }
        }
    }
    
    private var notInstalledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("agents.notInstalled".localized())
                .font(.headline)
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 8) {
                ForEach(notInstalledAgents) { status in
                    NotInstalledAgentCard(agent: status.agent)
                }
            }
        }
    }
}

private struct StatChip: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(value)
                .fontWeight(.semibold)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

private struct NotInstalledAgentCard: View {
    let agent: CLIAgent
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: agent.systemIcon)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            
            Text(agent.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            if let docsURL = agent.docsURL {
                Link(destination: docsURL) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    AgentSetupScreen()
        .environment(QuotaViewModel())
        .frame(width: 700, height: 600)
}
