//
//  MenuBarView.swift
//  Quotio
//
//  Redesigned menu bar panel with provider-first layout
//  Updated for Liquid Glass compatibility (macOS 15/26)
//

import SwiftUI

struct MenuBarView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarSelectedProvider") private var selectedProviderRaw: String = ""
    
    // MARK: - Computed Properties
    
    /// All providers that have quota data, sorted alphabetically
    private var providersWithData: [AIProvider] {
        var providers = Set<AIProvider>()
        
        // From providerQuotas
        for (provider, accountQuotas) in viewModel.providerQuotas {
            if !accountQuotas.isEmpty {
                providers.insert(provider)
            }
        }
        
        return providers.sorted { $0.displayName < $1.displayName }
    }
    
    /// Currently selected provider (auto-select first if invalid)
    private var selectedProvider: AIProvider? {
        // Try to use saved selection
        if !selectedProviderRaw.isEmpty,
           let provider = AIProvider(rawValue: selectedProviderRaw),
           providersWithData.contains(provider) {
            return provider
        }
        
        // Fallback to first provider with data
        return providersWithData.first
    }
    
    /// All quota data flattened
    private var allQuotas: [(provider: AIProvider, email: String, data: ProviderQuotaData, uniqueId: String)] {
        var result: [(provider: AIProvider, email: String, data: ProviderQuotaData, uniqueId: String)] = []
        
        for (provider, quotas) in viewModel.providerQuotas {
            for (email, data) in quotas where !data.models.isEmpty {
                let uniqueId = "\(provider.rawValue)_\(email)"
                result.append((provider: provider, email: email, data: data, uniqueId: uniqueId))
            }
        }
        
        return result.sorted { $0.provider.displayName < $1.provider.displayName }
    }
    
    /// Filtered quotas for selected provider
    private var filteredQuotas: [(provider: AIProvider, email: String, data: ProviderQuotaData, uniqueId: String)] {
        guard let selected = selectedProvider else { return [] }
        return allQuotas.filter { $0.provider == selected }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
                .padding(.vertical, 8)
            
            if !providersWithData.isEmpty {
                providerPickerSection
                
                Divider()
                    .padding(.vertical, 8)
                
                accountsSection
                
                Divider()
                    .padding(.vertical, 8)
            } else {
                emptyStateSection
                
                Divider()
                    .padding(.vertical, 8)
            }
            
            actionsSection
        }
        .padding(12)
        .frame(width: 300)
        .background(.clear)  // Ensure transparent background for NSVisualEffectView
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            Text("Quotio")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            refreshButton
        }
    }
    
    private var refreshButton: some View {
        Button {
            Task { await viewModel.refreshQuotasDirectly() }
        } label: {
            if viewModel.isLoadingQuotas {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("action.refresh".localized())
        .disabled(viewModel.isLoadingQuotas)
    }
    
    // MARK: - Provider Picker Section
    
    private var providerPickerSection: some View {
        HStack(spacing: 6) {
            ForEach(providersWithData) { provider in
                ProviderPickerButton(
                    provider: provider,
                    isSelected: selectedProvider == provider,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedProviderRaw = provider.rawValue
                        }
                    }
                )
            }
            Spacer()
        }
    }
    
    // MARK: - Accounts Section
    
    private var accountsSection: some View {
        VStack(spacing: 8) {
            ForEach(filteredQuotas, id: \.uniqueId) { item in
                QuotaAccountRow(provider: item.provider, email: item.email, data: item.data)
            }
        }
    }
    
    // MARK: - Empty State Section
    
    private var emptyStateSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            
            Text("menubar.noData".localized())
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(spacing: 4) {
            // Open main window
            Button {
                openMainWindow()
            } label: {
                HStack {
                    Image(systemName: "macwindow")
                    Text("menubar.openApp".localized())
                    Spacer()
                    Text("⌘O")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            
            Divider()
                .padding(.vertical, 4)
            
            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("menubar.quit".localized())
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }
    
    // MARK: - Helpers
    
    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if let window = NSApplication.shared.windows.first(where: { 
            $0.title == "Quotio" && $0.isVisible == false 
        }) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApplication.shared.windows.first(where: { 
            $0.title == "Quotio" 
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

// MARK: - Provider Picker Button

private struct ProviderPickerButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button {
            onTap()
        } label: {
            ProviderIcon(provider: provider, size: 20)
                .padding(6)
                .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Quota Account Row

private struct QuotaAccountRow: View {
    let provider: AIProvider
    let email: String
    let data: ProviderQuotaData
    
    private var lowestQuotaModel: ModelQuota? {
        data.models.min { $0.percentage < $1.percentage }
    }
    
    private var overallColor: Color {
        guard let lowest = lowestQuotaModel else { return .gray }
        let remaining = lowest.percentage
        if remaining > 50 { return .green }
        if remaining > 20 { return .orange }
        return .red
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider, size: 14)
                
                Text(email)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Spacer()
                
                if data.isForbidden {
                    Text("Limit")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            
            if !data.models.isEmpty {
                HStack(spacing: 8) {
                    if provider == .antigravity && data.hasGroupedModels {
                        ForEach(data.groupedModels.prefix(3)) { groupedModel in
                            GroupedQuotaModelBadge(groupedModel: groupedModel)
                        }
                    } else {
                        ForEach(data.models.sorted { $0.name < $1.name }.prefix(3)) { model in
                            QuotaModelBadge(model: model)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Quota Model Badge

private struct QuotaModelBadge: View {
    let model: ModelQuota
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var remainingPercent: Double {
        model.percentage
    }
    
    private var tintColor: Color {
        if remainingPercent > 50 { return .green }
        if remainingPercent > 20 { return .orange }
        return .red
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode.displayValue(from: remainingPercent)
        
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            HStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(tintColor)
                            .frame(width: proxy.size.width * min(1, remainingPercent / 100))
                            .animation(.smooth(duration: 0.3), value: remainingPercent)
                    }
                }
                .frame(height: 4)
                
                Text(verbatim: "\(Int(displayPercent))%")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Grouped Quota Model Badge

private struct GroupedQuotaModelBadge: View {
    let groupedModel: GroupedModelQuota
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var remainingPercent: Double {
        groupedModel.percentage
    }
    
    private var tintColor: Color {
        if remainingPercent > 50 { return .green }
        if remainingPercent > 20 { return .orange }
        return .red
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode.displayValue(from: remainingPercent)
        
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: groupedModel.group.icon)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                
                Text(groupedModel.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            HStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(tintColor)
                            .frame(width: proxy.size.width * min(1, remainingPercent / 100))
                            .animation(.smooth(duration: 0.3), value: remainingPercent)
                    }
                }
                .frame(height: 4)
                
                Text(verbatim: "\(Int(displayPercent))%")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIcon: View {
    let isRunning: Bool
    let readyAccounts: Int
    let totalAccounts: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isRunning ? .green : .secondary)
            
            if isRunning && totalAccounts > 0 {
                Text("\(readyAccounts)/\(totalAccounts)")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
        }
    }
}
