//
//  QuotaCard.swift
//  CKota
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
        guard let quotaData else { return false }
        return quotaData.values.contains { !$0.models.isEmpty }
    }

    private var aggregatedModels: [String: (remainingPercent: Double, resetTime: String, count: Int)] {
        guard let quotaData else { return [:] }

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
            (
                remainingPercent: value.total / Double(max(value.count, 1)),
                resetTime: value.resetTime,
                count: value.count
            )
        }
    }

    private var overallStatus: CKStatusDot.Status {
        if readyCount > 0 { return .ready }
        if coolingCount > 0 { return .cooling }
        return .exhausted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .ckLG) {
            headerSection

            if hasRealQuotaData {
                realQuotaSection
            } else {
                estimatedQuotaSection
            }

            Divider()
                .background(Color.ckBorder)

            statusBreakdownSection

            accountListSection
        }
        .ckCard()
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            ProviderIcon(provider: provider, size: 32)

            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(provider.displayName)
                    .font(.ckHeadline)
                Text(verbatim: "\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)
            }

            Spacer()

            CKStatusDot(status: overallStatus)
        }
    }

    // MARK: - Real Quota (from API)

    private var realQuotaSection: some View {
        VStack(spacing: .ckMD) {
            ForEach(Array(aggregatedModels.keys.sorted()), id: \.self) { modelName in
                if let data = aggregatedModels[modelName] {
                    let displayName = ModelQuota(name: modelName, percentage: 0.0, resetTime: "").displayName
                    CKQuotaSection(
                        title: displayName,
                        remainingPercent: data.remainingPercent,
                        resetTime: data.resetTime
                    )
                }
            }
        }
    }

    // MARK: - Estimated Quota (fallback)

    private var estimatedQuotaSection: some View {
        VStack(spacing: .ckMD) {
            CKQuotaSection(
                title: "Session",
                remainingPercent: sessionRemainingPercent,
                resetTime: sessionResetTime
            )

            if provider == .claude {
                CKQuotaSection(
                    title: "Weekly",
                    remainingPercent: weeklyRemainingPercent,
                    resetTime: weeklyResetTime
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
        100 - min(
            100,
            Double(errorCount) / Double(max(accounts.count, 1)) * 100 + (100 - sessionRemainingPercent) * 0.3
        )
    }

    private var sessionResetTime: String {
        if let coolingAccount = accounts.first(where: { $0.status == "cooling" }),
           let message = coolingAccount.statusMessage,
           let minutes = parseMinutes(from: message)
        {
            return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
        }
        return coolingCount > 0 ? "~1h" : ""
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
              let number = Int(message[numberRange])
        else {
            return nil
        }

        let unit = String(message[unitRange]).lowercased()
        return unit.hasPrefix("h") ? number * 60 : number
    }

    // MARK: - Status Breakdown

    private var statusBreakdownSection: some View {
        HStack(spacing: .ckLG) {
            CKStatusBadge(count: readyCount, label: "Ready", status: .ready)
            CKStatusBadge(count: coolingCount, label: "Cooling", status: .cooling)
            CKStatusBadge(count: errorCount, label: "Error", status: .exhausted)
        }
    }

    // MARK: - Account List

    private var accountListSection: some View {
        DisclosureGroup {
            VStack(spacing: .ckXS) {
                ForEach(accounts) { account in
                    CKAccountRow(account: account, quotaData: quotaData?[account.quotaLookupKey])
                }
            }
        } label: {
            Text("Accounts")
                .font(.ckCaption)
                .foregroundStyle(Color.ckMutedForeground)
        }
    }
}

// MARK: - Status Badge

private struct CKStatusBadge: View {
    let count: Int
    let label: String
    let status: CKStatusDot.Status

    var body: some View {
        HStack(spacing: .ckXS) {
            CKStatusDot(status: status, showLabel: false)
            Text("\(count)")
                .font(.ckBodyMedium)
            Text(label)
                .font(.ckCallout)
                .foregroundStyle(Color.ckMutedForeground)
        }
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
        ),
    ]

    let mockQuota: [String: ProviderQuotaData] = [
        "[email protected]": ProviderQuotaData(
            models: [
                ModelQuota(name: "gemini-3-pro-high", percentage: 65.0, resetTime: "2025-12-25T00:00:00Z"),
                ModelQuota(name: "gemini-3-flash", percentage: 80.0, resetTime: "2025-12-25T00:00:00Z"),
                ModelQuota(name: "claude-sonnet-4-5-thinking", percentage: 45.0, resetTime: "2025-12-25T00:00:00Z"),
            ]
        ),
    ]

    return QuotaCard(provider: .antigravity, accounts: mockAccounts, quotaData: mockQuota)
        .frame(width: 400)
        .padding()
        .background(Color.ckBackground)
}
