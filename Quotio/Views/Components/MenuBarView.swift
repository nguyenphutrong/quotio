//
//  MenuBarView.swift
//  Quotio
//
//  Card-based menu bar panel with hero metric design.
//  Each card has ONE dominant metric + secondary metrics list.
//

import SwiftUI

// MARK: - Softer Color Palette

private extension Color {
    static let quotaGreen = Color(red: 0.35, green: 0.68, blue: 0.45)   // Muted green
    static let quotaYellow = Color(red: 0.85, green: 0.65, blue: 0.25)  // Warm yellow
    static let quotaOrange = Color(red: 0.9, green: 0.45, blue: 0.3)    // Soft orange/red
}

// MARK: - Hero Metric Selection

/// Priority levels for hero metric selection
private enum MetricPriority: Int, Comparable {
    case primary = 0    // Hard limits: weekly, monthly, plan
    case secondary = 1  // Session, fast/slow requests
    case subset = 2     // Sonnet-only, completions (never hero unless only option)
    
    static func < (lhs: MetricPriority, rhs: MetricPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Determines metric priority for hero selection
private func metricPriority(for name: String) -> MetricPriority {
    let lowered = name.lowercased()
    
    // Subset metrics - lowest priority
    if lowered.contains("sonnet") || lowered.contains("completion") {
        return .subset
    }
    
    // Primary hard limits
    if lowered.contains("weekly") || lowered.contains("monthly") ||
       lowered.contains("plan") || lowered.contains("quota") ||
       lowered.contains("usage") {
        return .primary
    }
    
    // Secondary metrics
    return .secondary
}

/// Select hero metric from a list of models
private func selectHeroMetric(from models: [ModelQuota]) -> ModelQuota? {
    guard !models.isEmpty else { return nil }
    
    // Sort by: priority (ascending), then by used% (descending)
    let sorted = models.sorted { a, b in
        let priorityA = metricPriority(for: a.name)
        let priorityB = metricPriority(for: b.name)
        
        if priorityA != priorityB {
            return priorityA < priorityB
        }
        
        // Higher usage (lower remaining %) = more urgent
        return a.percentage < b.percentage
    }
    
    return sorted.first
}

/// Select hero from grouped models (for Antigravity)
private func selectHeroFromGroups(_ groups: [GroupedModelQuota]) -> GroupedModelQuota? {
    guard !groups.isEmpty else { return nil }
    // Pick the group with lowest remaining percentage (most urgent)
    return groups.min { $0.percentage < $1.percentage }
}

// MARK: - Quota Color Helper

private func quotaColor(for percentage: Double) -> Color {
    let used = 100 - percentage
    if used >= 90 { return .quotaOrange }
    if used >= 70 { return .quotaYellow }
    return .quotaGreen
}

// MARK: - Main View

struct MenuBarView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("menuBarSelectedProvider") private var selectedProviderRaw: String = ""
    
    private let modeManager = AppModeManager.shared
    
    // MARK: - Computed Properties
    
    private var providersWithData: [AIProvider] {
        var providers = Set<AIProvider>()
        for (provider, accountQuotas) in viewModel.providerQuotas {
            if !accountQuotas.isEmpty {
                providers.insert(provider)
            }
        }
        return providers.sorted { $0.displayName < $1.displayName }
    }
    
    private var selectedProvider: AIProvider? {
        if !selectedProviderRaw.isEmpty,
           let provider = AIProvider(rawValue: selectedProviderRaw),
           providersWithData.contains(provider) {
            return provider
        }
        return providersWithData.first
    }
    
    private var filteredQuotas: [(email: String, data: ProviderQuotaData)] {
        guard let selected = selectedProvider,
              let quotas = viewModel.providerQuotas[selected] else { return [] }
        return quotas.map { ($0.key, $0.value) }.sorted { $0.email < $1.email }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            // Full Mode: Proxy info section (after header)
            if modeManager.isFullMode {
                Divider()
                    .padding(.vertical, 8)
                
                proxyInfoSection
            }
            
            if !providersWithData.isEmpty {
                Divider()
                    .padding(.vertical, 8)
                
                providerFilterSection
                
                Divider()
                    .padding(.vertical, 8)
                
                accountCardsSection
            } else {
                Divider()
                    .padding(.vertical, 8)
                
                emptyStateSection
            }
            
            Divider()
                .padding(.vertical, 8)
            
            actionsSection
        }
        .padding(12)
        .frame(width: 300)
        .background(.clear)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            Text("Quotio")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            if viewModel.isLoadingQuotas {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
    
    // MARK: - Proxy Info (Full Mode)
    
    private var proxyInfoSection: some View {
        let portString = String(viewModel.proxyManager.port)
        
        return VStack(spacing: 8) {
            // Proxy URL
            HStack {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("http://localhost:\(portString)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                
                Spacer()
                
                Button {
                    let url = "http://localhost:\(portString)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            // Proxy Status
            HStack {
                Circle()
                    .fill(viewModel.proxyManager.proxyStatus.running ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                
                Text(viewModel.proxyManager.proxyStatus.running 
                     ? "status.running".localized() 
                     : "status.stopped".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    Task { await viewModel.toggleProxy() }
                } label: {
                    Text(viewModel.proxyManager.proxyStatus.running 
                         ? "action.stop".localized() 
                         : "action.start".localized())
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.proxyManager.proxyStatus.running ? .red : .green)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(spacing: 4) {
            // Refresh
            MenuBarActionButton(
                icon: "arrow.clockwise",
                title: "action.refresh".localized(),
                isLoading: viewModel.isLoadingQuotas
            ) {
                Task {
                    await viewModel.refreshQuotasUnified()
                }
            }
            .disabled(viewModel.isLoadingQuotas)
            
            // Open Quotio
            MenuBarActionButton(
                icon: "macwindow",
                title: "action.openApp".localized()
            ) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Quotio" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            
            // Quit Quotio
            MenuBarActionButton(
                icon: "xmark.circle",
                title: "action.quit".localized()
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    // MARK: - Provider Filter
    
    private var providerFilterSection: some View {
        FlowLayout(spacing: 6) {
            ForEach(providersWithData) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: selectedProvider == provider
                ) {
                    selectedProviderRaw = provider.rawValue
                }
            }
        }
    }
    
    // MARK: - Account Cards
    
    private var accountCardsSection: some View {
        VStack(spacing: 8) {
            ForEach(filteredQuotas, id: \.email) { item in
                MenuBarQuotaCard(
                    email: item.email,
                    data: item.data,
                    provider: selectedProvider ?? .gemini
                )
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateSection: some View {
        VStack(spacing: 6) {
            Text("No quota data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Provider Filter Button

private struct ProviderFilterButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // Monochrome icon
                ProviderIconMono(provider: provider, size: 14)
                
                Text(provider.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.secondary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Monochrome Provider Icon

private struct ProviderIconMono: View {
    let provider: AIProvider
    let size: CGFloat
    
    var body: some View {
        Group {
            if let assetName = provider.menuBarIconAsset,
               let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .colorMultiply(.primary)
            } else {
                Image(systemName: provider.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Quota Card

private struct MenuBarQuotaCard: View {
    let email: String
    let data: ProviderQuotaData
    let provider: AIProvider
    
    @State private var isHovered = false
    
    // For Antigravity: use grouped models
    private var isAntigravity: Bool {
        provider == .antigravity && data.hasGroupedModels
    }
    
    private var groupedModels: [GroupedModelQuota] {
        data.groupedModels
    }
    
    private var heroGroup: GroupedModelQuota? {
        selectHeroFromGroups(groupedModels)
    }
    
    private var secondaryGroups: [GroupedModelQuota] {
        guard let hero = heroGroup else { return groupedModels }
        return groupedModels.filter { $0.id != hero.id }
    }
    
    // For other providers: use regular models
    private var heroMetric: ModelQuota? {
        selectHeroMetric(from: data.models)
    }
    
    private var secondaryMetrics: [ModelQuota] {
        guard let hero = heroMetric else { return data.models }
        return data.models.filter { $0.name != hero.name }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Email + Plan
            cardHeader
            
            // Hero section (different for Antigravity)
            if isAntigravity {
                if let hero = heroGroup {
                    heroGroupSection(group: hero)
                }
            } else {
                if let hero = heroMetric {
                    heroSection(metric: hero)
                }
            }
            
            // Secondary section
            if isAntigravity {
                if !secondaryGroups.isEmpty {
                    secondaryGroupsSection
                }
            } else {
                if !secondaryMetrics.isEmpty {
                    secondaryMetricsSection
                }
            }
        }
        .padding(10)
        .background(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Card Header
    
    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(email)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            
            if let plan = data.planDisplayName {
                Text(plan)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Hero Section (Regular)
    
    private func heroSection(metric: ModelQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text(formatPercentage(metric.percentage))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(quotaColor(for: metric.percentage))
            }
            
            HeroProgressBar(percentage: metric.percentage)
            
            if !metric.formattedResetTime.isEmpty && metric.formattedResetTime != "—" {
                Text("Resets in \(metric.formattedResetTime)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    // MARK: - Hero Section (Antigravity Grouped)
    
    private func heroGroupSection(group: GroupedModelQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Image(systemName: group.group.icon)
                        .font(.system(size: 10))
                    Text(group.displayName)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Text(formatPercentage(group.percentage))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(quotaColor(for: group.percentage))
            }
            
            HeroProgressBar(percentage: group.percentage)
            
            if !group.formattedResetTime.isEmpty && group.formattedResetTime != "—" {
                Text("Resets in \(group.formattedResetTime)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    // MARK: - Secondary Section (Regular)
    
    private var secondaryMetricsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(secondaryMetrics.prefix(3)) { metric in
                SecondaryMetricRow(
                    name: metric.displayName,
                    percentage: metric.percentage
                )
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - Secondary Section (Antigravity Grouped)
    
    private var secondaryGroupsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(secondaryGroups.prefix(3)) { group in
                SecondaryGroupRow(group: group)
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - Helpers
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
    }
}

// MARK: - Hero Progress Bar

private struct HeroProgressBar: View {
    let percentage: Double
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                
                RoundedRectangle(cornerRadius: 3)
                    .fill(quotaColor(for: percentage))
                    .frame(width: proxy.size.width * min(1, max(0, percentage / 100)))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Secondary Metric Row

private struct SecondaryMetricRow: View {
    let name: String
    let percentage: Double
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(quotaColor(for: percentage))
                .frame(width: 6, height: 6)
            
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(formatPercentage(percentage))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
    }
}

// MARK: - Secondary Group Row (Antigravity)

private struct SecondaryGroupRow: View {
    let group: GroupedModelQuota
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(quotaColor(for: group.percentage))
                .frame(width: 6, height: 6)
            
            HStack(spacing: 3) {
                Image(systemName: group.group.icon)
                    .font(.system(size: 9))
                Text(group.displayName)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(formatPercentage(group.percentage))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
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

// MARK: - AIProvider Extension

private extension AIProvider {
    var shortName: String {
        switch self {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .codex: return "OpenAI"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .qwen: return "Qwen"
        case .iflow: return "iFlow"
        case .vertex: return "Vertex"
        case .kiro: return "Kiro"
        }
    }
}

// MARK: - Menu Bar Action Button

private struct MenuBarActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var rotation: Double = 0
    @State private var timer: Timer?
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .rotationEffect(.degrees(rotation))
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
                
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
        .onAppear {
            updateTimer()
        }
        .onChange(of: isLoading) { _, _ in
            updateTimer()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        
        if isLoading {
            // Use Timer for reliable animation in NSMenu context
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in
                    rotation += 18 // 360° / 20 steps = 18° per step
                    if rotation >= 360 {
                        rotation = 0
                    }
                }
            }
        } else {
            rotation = 0
        }
    }
}
