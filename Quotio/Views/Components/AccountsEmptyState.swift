//
//  AccountsEmptyState.swift
//  Quotio
//
//  Empty state view for when no accounts are connected.
//  Part of ProvidersScreen UI/UX redesign.
//

import SwiftUI

// MARK: - Accounts Empty State

struct AccountsEmptyState: View {
    var onScanIDEs: (() -> Void)?
    var onAddProvider: (() -> Void)?
    var isQuotaOnlyMode: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Illustration
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "person.2.badge.key")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
            
            // Text content
            VStack(spacing: 8) {
                Text("providers.emptyState.title".localized())
                    .font(.headline)
                
                Text("providers.emptyState.message".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                if let onScanIDEs = onScanIDEs {
                    Button {
                        onScanIDEs()
                    } label: {
                        Label("ideScan.title".localized(), systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                if let onAddProvider = onAddProvider {
                    Button {
                        onAddProvider()
                    } label: {
                        Label("providers.addManually".localized(), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Preview

#Preview {
    List {
        Section {
            AccountsEmptyState(
                onScanIDEs: { print("Scan IDEs") },
                onAddProvider: { print("Add provider") }
            )
        }
    }
}
