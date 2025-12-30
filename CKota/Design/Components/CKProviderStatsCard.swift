//
//  CKProviderStatsCard.swift
//  CKota
//
//  Provider stats card displaying account count, success/failure ratio,
//  and progress bar visualization for dashboard.
//

import SwiftUI

// MARK: - CKProviderStatsCard

/// Provider stats card with detailed metrics and visual indicators.
struct CKProviderStatsCard: View {
    let provider: AIProvider
    let accountCount: Int
    let successCount: Int
    let failureCount: Int

    private var totalRequests: Int {
        successCount + failureCount
    }

    private var successRate: Double {
        guard totalRequests > 0 else { return 1.0 }
        return Double(successCount) / Double(totalRequests)
    }

    private var successPercentage: Int {
        Int(successRate * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            // Header: Provider icon, name, and account count
            HStack(spacing: .ckSM) {
                ProviderIcon(provider: provider, size: 20)

                Text(provider.displayName)
                    .font(.ckBodyMedium)
                    .foregroundStyle(Color.ckForeground)

                Spacer()

                // Account count badge
                Text("\(accountCount)")
                    .font(.ckCaption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(provider.color.opacity(0.15))
                    )
                    .foregroundStyle(provider.color)
            }

            // Stats label
            Text("Stats")
                .font(.ckCaption)
                .foregroundStyle(Color.ckMutedForeground)
                .textCase(.uppercase)
                .tracking(0.5)

            // Progress bar showing success (green) vs failed (red) ratio
            CKDualProgressBar(
                successValue: successRate,
                failureValue: 1.0 - successRate
            )

            // Account dots and stats row
            HStack(spacing: .ckMD) {
                // Account status dots
                HStack(spacing: 3) {
                    ForEach(0 ..< min(accountCount, 6), id: \.self) { _ in
                        Circle()
                            .fill(provider.color)
                            .frame(width: 6, height: 6)
                    }
                    if accountCount > 6 {
                        Text("+\(accountCount - 6)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color.ckMutedForeground)
                    }
                }

                Spacer()

                // Stats: success, fail, rate
                HStack(spacing: .ckMD) {
                    // Success count
                    HStack(spacing: 2) {
                        Circle()
                            .fill(Color.ckSuccess)
                            .frame(width: 6, height: 6)
                        Text("\(successCount)")
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckSuccess)
                    }

                    // Failure count
                    HStack(spacing: 2) {
                        Circle()
                            .fill(Color.ckDestructive)
                            .frame(width: 6, height: 6)
                        Text("\(failureCount)")
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckDestructive)
                    }

                    // Rate percentage
                    Text("\(successPercentage)%")
                        .font(.ckCaption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.ckMutedForeground)
                }
            }
        }
        .padding(.ckMD)
        .background(
            RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                .fill(Color.ckCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                .stroke(Color.ckBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(provider.displayName): \(accountCount) accounts, \(successCount) successful, \(failureCount) failed, \(successPercentage)% success rate"
        )
    }
}

// MARK: - CKDualProgressBar

/// Progress bar showing success (green) and failure (red) portions.
struct CKDualProgressBar: View {
    let successValue: Double
    let failureValue: Double

    private var clampedSuccess: Double {
        min(max(successValue, 0), 1)
    }

    private var clampedFailure: Double {
        min(max(failureValue, 0), 1 - clampedSuccess)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                // Success portion (green)
                if clampedSuccess > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.ckSuccess)
                        .frame(width: geometry.size.width * clampedSuccess)
                }

                // Failure portion (red)
                if clampedFailure > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.ckDestructive)
                        .frame(width: geometry.size.width * clampedFailure)
                }

                // Empty portion (if neither success nor failure fills it)
                if clampedSuccess + clampedFailure < 1 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.ckMuted)
                }
            }
        }
        .frame(height: 4)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.ckMuted)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - CKLiveBadge

/// Live status badge with pulse animation.
struct CKLiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                // Pulse ring
                if !reduceMotion {
                    Circle()
                        .fill(Color.ckSuccess.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(isPulsing ? 2.0 : 1.0)
                        .opacity(isPulsing ? 0 : 0.6)
                        .animation(
                            .easeOut(duration: 1.2)
                                .repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                }

                // Center dot
                Circle()
                    .fill(Color.ckSuccess)
                    .frame(width: 6, height: 6)
            }

            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.ckSuccess)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.ckSuccess.opacity(0.15))
        )
        .onAppear {
            isPulsing = true
        }
        .accessibilityLabel("Live status: actively monitoring")
    }
}

// MARK: - Preview

#Preview("CKProviderStatsCard") {
    VStack(spacing: .ckMD) {
        Text("Provider Stats Cards")
            .font(.ckTitle)

        CKProviderStatsCard(
            provider: .claude,
            accountCount: 3,
            successCount: 85,
            failureCount: 2
        )

        CKProviderStatsCard(
            provider: .antigravity,
            accountCount: 2,
            successCount: 54,
            failureCount: 1
        )

        Divider()

        Text("Live Badge")
            .font(.ckHeadline)

        CKLiveBadge()
    }
    .padding()
    .frame(width: 300)
    .background(Color.ckBackground)
}
