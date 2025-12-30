//
//  CKAccountRow.swift
//  CKota
//
//  Account row displaying status dot, email/name, and quota info.
//  Used in QuotaCard account lists.
//

import SwiftUI

// MARK: - CKAccountRow

/// Account row with status indicator and optional quota display.
struct CKAccountRow: View {
    let account: AuthFile
    var quotaData: ProviderQuotaData?

    private var displayName: String {
        account.email ?? account.name
    }

    private var status: CKStatusDot.Status {
        switch account.status.lowercased() {
        case "ready" where !account.disabled: .ready
        case "cooling": .cooling
        case "error", "exhausted": .exhausted
        default: account.unavailable ? .exhausted : .unknown
        }
    }

    var body: some View {
        HStack(spacing: .ckSM) {
            CKStatusDot(status: status, showLabel: false)

            Text(displayName)
                .font(.ckCallout)
                .lineLimit(1)

            Spacer()

            trailingContent
        }
        .padding(.vertical, .ckXS)
    }

    @ViewBuilder
    private var trailingContent: some View {
        if let quotaData, !quotaData.models.isEmpty {
            HStack(spacing: .ckXS) {
                ForEach(quotaData.models.prefix(2)) { model in
                    quotaPercentageTag(model.percentage)
                }
            }
        } else if let statusMessage = account.statusMessage, !statusMessage.isEmpty {
            Text(statusMessage)
                .font(.ckCaption)
                .foregroundStyle(Color.ckMutedForeground)
                .lineLimit(1)
        } else {
            Text(account.status.capitalized)
                .font(.ckCallout)
                .foregroundStyle(status.color)
        }
    }

    private func quotaPercentageTag(_ percentage: Double) -> some View {
        let color: Color = percentage > 50 ? .ckSuccess : (percentage > 20 ? .ckWarning : .ckDestructive)

        return Text("\(Int(percentage))%")
            .font(.ckCaption)
            .foregroundStyle(color)
    }
}

// MARK: - Preview

#Preview("CKAccountRow") {
    VStack(alignment: .leading, spacing: .ckLG) {
        Text("Account Rows")
            .font(.ckTitle)

        VStack(spacing: .ckXS) {
            CKAccountRow(
                account: AuthFile(
                    id: "1",
                    name: "[email protected]",
                    provider: "claude",
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
                quotaData: ProviderQuotaData(models: [
                    ModelQuota(name: "claude-sonnet", percentage: 75, resetTime: ""),
                ])
            )

            CKAccountRow(
                account: AuthFile(
                    id: "2",
                    name: "[email protected]",
                    provider: "gemini",
                    label: nil,
                    status: "cooling",
                    statusMessage: "45 min remaining",
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
            )

            CKAccountRow(
                account: AuthFile(
                    id: "3",
                    name: "[email protected]",
                    provider: "codex",
                    label: nil,
                    status: "error",
                    statusMessage: nil,
                    disabled: false,
                    unavailable: true,
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
            )
        }
        .ckCard()
    }
    .padding()
    .frame(width: 400)
    .background(Color.ckBackground)
}
