//
//  QuotaCard.swift
//  Quotio
//

import SwiftUI

struct QuotaCard: View {
    let provider: AIProvider
    let accounts: [AuthFile]
    var quotaData: [String: ProviderQuotaData]?
    
    private var readyCount: Int {
        accounts.filter { $0.status == "ready" && !$0.disabled }.count
    }
    
    private var coolingCount: Int {
        accounts.filter { $0.status == "cooling" }.count
    }
    
    private var errorCount: Int {
        accounts.filter { $0.status == "error" || $0.unavailable }.count
    }
    
    private var hasRealQuotaData: Bool {
        guard let quotaData = quotaData else { return false }
        return quotaData.values.contains { !$0.models.isEmpty }
    }
    
    private var aggregatedModels: [String: (remainingPercent: Double, resetTime: String, count: Int)] {
        guard let quotaData = quotaData else { return [:] }
        
        var result: [String: (total: Double, resetTime: String, count: Int)] = [:]
        
        for (_, data) in quotaData {
            for model in data.models {
                let existing = result[model.name] ?? (total: 0, resetTime: model.formattedResetTime, count: 0)
                result[model.name] = (
                    total: existing.total + Double(model.percentage),
                    resetTime: model.formattedResetTime,
                    count: existing.count + 1
                )
            }
        }
        
        return result.mapValues { value in
            (remainingPercent: value.total / Double(max(value.count, 1)), resetTime: value.resetTime, count: value.count)
        }
    }
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                
                if hasRealQuotaData {
                    realQuotaSection
                } else {
                    estimatedQuotaSection
                }
                
                Divider()
                
                statusBreakdownSection
                
                accountListSection
            }
            .padding(4)
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            ProviderIcon(provider: provider, size: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.headline)
                Text(verbatim: "\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Circle()
                    .fill(readyCount > 0 ? .green : (coolingCount > 0 ? .orange : .red))
                    .frame(width: 10, height: 10)
                Text(readyCount > 0 ? "Available" : (coolingCount > 0 ? "Cooling" : "Error"))
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
    }
    
    // MARK: - Real Quota (from API)
    
    private var realQuotaSection: some View {
        VStack(spacing: 12) {
            ForEach(Array(aggregatedModels.keys.sorted()), id: \.self) { modelName in
                if let data = aggregatedModels[modelName] {
                    let displayName = ModelQuota(name: modelName, percentage: 0.0, resetTime: "").displayName
                    QuotaSection(
                        title: displayName,
                        remainingPercent: data.remainingPercent,
                        resetTime: data.resetTime,
                        tint: data.remainingPercent > 50 ? .green : (data.remainingPercent > 20 ? .orange : .red)
                    )
                }
            }
        }
    }
    
    // MARK: - Estimated Quota (fallback)
    
    private var estimatedQuotaSection: some View {
        VStack(spacing: 12) {
            QuotaSection(
                title: "Session",
                remainingPercent: sessionRemainingPercent,
                resetTime: sessionResetTime,
                tint: sessionRemainingPercent > 50 ? .green : (sessionRemainingPercent > 20 ? .orange : .red)
            )
            
            if provider == .claude || provider == .codex {
                QuotaSection(
                    title: "Weekly",
                    remainingPercent: weeklyRemainingPercent,
                    resetTime: weeklyResetTime,
                    tint: weeklyRemainingPercent > 50 ? .green : (weeklyRemainingPercent > 20 ? .orange : .red)
                )
            }
        }
    }
    
    private var sessionRemainingPercent: Double {
        guard !accounts.isEmpty else { return 100 }
        let readyCount = accounts.filter { $0.status == "ready" && !$0.disabled }.count
        return Double(readyCount) / Double(accounts.count) * 100
    }
    
    private var weeklyRemainingPercent: Double {
        100 - min(100, Double(errorCount) / Double(max(accounts.count, 1)) * 100 + (100 - sessionRemainingPercent) * 0.3)
    }
    
    private var sessionResetTime: String {
        if let coolingAccount = accounts.first(where: { $0.status == "cooling" }),
           let message = coolingAccount.statusMessage,
           let minutes = parseMinutes(from: message) {
            return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
        }
        return coolingCount > 0 ? "~1h" : "—"
    }
    
    private var weeklyResetTime: String {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilMonday = (9 - weekday) % 7
        return daysUntilMonday == 0 ? "today" : "\(daysUntilMonday)d"
    }
    
    private func parseMinutes(from message: String) -> Int? {
        let pattern = #"(\d+)\s*(minute|min|hour|hr|h|m)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let numberRange = Range(match.range(at: 1), in: message),
              let unitRange = Range(match.range(at: 2), in: message),
              let number = Int(message[numberRange]) else {
            return nil
        }
        
        let unit = String(message[unitRange]).lowercased()
        return unit.hasPrefix("h") ? number * 60 : number
    }
    
    // MARK: - Status Breakdown
    
    private var statusBreakdownSection: some View {
        HStack(spacing: 16) {
            StatusBadge(count: readyCount, label: "Ready", color: .green)
            StatusBadge(count: coolingCount, label: "Cooling", color: .orange)
            StatusBadge(count: errorCount, label: "Error", color: .red)
        }
        .font(.caption)
    }
    
    // MARK: - Account List
    
    private var accountListSection: some View {
        DisclosureGroup {
            VStack(spacing: 4) {
                ForEach(accounts) { account in
                    AccountRow(account: account, quotaData: quotaData?[account.quotaLookupKey])
                }
            }
        } label: {
            Text("Accounts")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Quota Section

private struct QuotaSection: View {
    let title: String
    let remainingPercent: Double
    let resetTime: String
    let tint: Color
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var progressWidth: Double {
        remainingPercent / 100
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode.displayValue(from: remainingPercent)
        
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                HStack(spacing: 8) {
                    Text(verbatim: "\(Int(displayPercent))% \(displayMode.suffixKey.localized())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if resetTime != "—" {
                        Text("•")
                            .foregroundStyle(.quaternary)
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(verbatim: "reset \(resetTime)")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(1, progressWidth))
                        .animation(.smooth(duration: 0.3), value: progressWidth)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Supporting Views

private struct StatusBadge: View {
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(verbatim: "\(count) \(label)")
                .foregroundStyle(count > 0 ? .primary : .secondary)
        }
    }
}

private struct AccountRow: View {
    let account: AuthFile
    var quotaData: ProviderQuotaData?
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.statusColor)
                .frame(width: 8, height: 8)
            
            Text(account.email ?? account.name)
                .font(.caption)
                .lineLimit(1)
            
            Spacer()
            
            if let quotaData = quotaData, !quotaData.models.isEmpty {
                HStack(spacing: 4) {
                    ForEach(quotaData.models.prefix(2)) { model in
                        Text(verbatim: "\(model.percentage)%")
                            .font(.caption2)
                            .foregroundStyle(model.percentage > 50 ? .green : (model.percentage > 20 ? .orange : .red))
                    }
                }
            } else if let statusMessage = account.statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(account.status.capitalized)
                    .font(.caption)
                    .foregroundStyle(account.statusColor)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let mockAccounts = [
        AuthFile(
            id: "1",
            name: "[email protected]",
            provider: "antigravity",
            label: nil,
            status: "ready",
            statusMessage: nil,
            disabled: false,
            unavailable: false,
            runtimeOnly: false,
            source: "file",
            path: nil,
            email: "[email protected]",
            accountType: nil,
            account: nil,
            createdAt: nil,
            updatedAt: nil,
            lastRefresh: nil
        )
    ]
    
    let mockQuota: [String: ProviderQuotaData] = [
        "[email protected]": ProviderQuotaData(
            models: [
                ModelQuota(name: "gemini-3-pro-high", percentage: 65.0, resetTime: "2025-12-25T00:00:00Z"),
                ModelQuota(name: "gemini-3-flash", percentage: 80.0, resetTime: "2025-12-25T00:00:00Z"),
                ModelQuota(name: "claude-sonnet-4-5-thinking", percentage: 45.0, resetTime: "2025-12-25T00:00:00Z")
            ]
        )
    ]
    
    return QuotaCard(provider: .antigravity, accounts: mockAccounts, quotaData: mockQuota)
        .frame(width: 400)
        .padding()
}
