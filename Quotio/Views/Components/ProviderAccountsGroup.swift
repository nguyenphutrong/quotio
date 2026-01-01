//
//  ProviderAccountsGroup.swift
//  Quotio
//
//  A collapsible group that displays accounts for a single provider.
//  Used in ProvidersScreen to organize accounts by provider.
//

import SwiftUI

/// Represents a group of accounts for a single provider
struct ProviderAccountsGroupData: Identifiable {
    let provider: AIProvider
    var accounts: [AccountRowData]
    
    var id: String { provider.rawValue }
    var count: Int { accounts.count }
    var isEmpty: Bool { accounts.isEmpty }
    
    /// Create groups from a list of accounts
    static func group(_ accounts: [AccountRowData]) -> [ProviderAccountsGroupData] {
        // Group by provider
        var grouped: [AIProvider: [AccountRowData]] = [:]
        for account in accounts {
            grouped[account.provider, default: []].append(account)
        }
        
        // Convert to array and sort by provider display name
        return grouped.map { provider, accounts in
            ProviderAccountsGroupData(provider: provider, accounts: accounts)
        }.sorted { $0.provider.displayName < $1.provider.displayName }
    }
}

// MARK: - Provider Accounts Group View

struct ProviderAccountsGroup: View {
    let group: ProviderAccountsGroupData
    var onDeleteAccount: ((AccountRowData) -> Void)?
    
    @State private var isExpanded: Bool = true
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.accounts) { account in
                AccountRow(
                    account: account,
                    onDelete: account.canDelete ? { onDeleteAccount?(account) } : nil
                )
            }
        } label: {
            providerLabel
        }
    }
    
    // MARK: - Provider Label
    
    private var providerLabel: some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: group.provider, size: 20)
            
            Text(group.provider.displayName)
                .fontWeight(.medium)
            
            // Account count badge
            Text("\(group.count)")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(group.provider.color.opacity(0.15))
                .foregroundStyle(group.provider.color)
                .clipShape(Capsule())
            
            Spacer()
            
            // Source indicator for auto-detected providers
            if group.accounts.allSatisfy({ $0.source == .autoDetected }) {
                Text("providers.autoDetected".localized())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - All Accounts Group View

/// A section that displays all accounts grouped by provider
struct AllAccountsSection: View {
    let accounts: [AccountRowData]
    var onDeleteAccount: ((AccountRowData) -> Void)?
    var onRefresh: (() async -> Void)?
    
    @State private var isRefreshing = false
    
    private var groups: [ProviderAccountsGroupData] {
        ProviderAccountsGroupData.group(accounts)
    }
    
    var body: some View {
        Section {
            if accounts.isEmpty {
                emptyState
            } else {
                ForEach(groups) { group in
                    ProviderAccountsGroup(
                        group: group,
                        onDeleteAccount: onDeleteAccount
                    )
                }
            }
        } header: {
            sectionHeader
        } footer: {
            if !accounts.isEmpty {
                MenuBarHintView()
            }
        }
    }
    
    // MARK: - Section Header
    
    private var sectionHeader: some View {
        HStack {
            Label(
                "providers.yourAccounts".localized() + " (\(accounts.count))",
                systemImage: "person.2.badge.key"
            )
            
            Spacer()
            
            if let onRefresh = onRefresh {
                Button {
                    Task {
                        isRefreshing = true
                        await onRefresh()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        SmallProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.sectionHeader)
                .disabled(isRefreshing)
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            
            Text("providers.noAccountsYet".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("providers.addAccountHint".localized())
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Preview

#Preview {
    List {
        AllAccountsSection(
            accounts: [
                AccountRowData(
                    id: "1",
                    provider: .gemini,
                    displayName: "user@gmail.com",
                    source: .proxy,
                    status: "ready",
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: true
                ),
                AccountRowData(
                    id: "2",
                    provider: .gemini,
                    displayName: "work@company.com",
                    source: .proxy,
                    status: "ready",
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: true
                ),
                AccountRowData(
                    id: "3",
                    provider: .claude,
                    displayName: "dev@example.com",
                    source: .direct,
                    status: nil,
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: false
                ),
                AccountRowData(
                    id: "4",
                    provider: .cursor,
                    displayName: "cursor@email.com",
                    source: .autoDetected,
                    status: nil,
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: false
                )
            ],
            onDeleteAccount: { _ in },
            onRefresh: {}
        )
    }
}
