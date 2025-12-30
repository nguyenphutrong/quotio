//
//  CKQuotaSection.swift
//  CKota
//
//  Quota section displaying model name, percentage, reset time, and progress bar.
//  Replaces inline QuotaSection with CCS design system styling.
//

import SwiftUI

// MARK: - CKQuotaSection

/// Quota progress section with label, percentage, and reset time.
struct CKQuotaSection: View {
    let title: String
    let remainingPercent: Double
    var resetTime: String = ""

    @State private var settings = MenuBarSettingsManager.shared

    /// Progress value from 0 to 1
    private var progressValue: Double {
        remainingPercent / 100
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode.displayValue(from: remainingPercent)

        VStack(alignment: .leading, spacing: .ckSM) {
            HStack {
                Text(title)
                    .font(.ckBodyMedium)

                Spacer()

                HStack(spacing: .ckSM) {
                    Text("\(Int(displayPercent))% \(displayMode.suffixKey.localized())")
                        .font(.ckCallout)
                        .foregroundStyle(Color.ckMutedForeground)

                    if !resetTime.isEmpty, resetTime != "—" {
                        Text("•")
                            .foregroundStyle(Color.ckMuted)

                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text("reset \(resetTime)")
                                .font(.ckCaption)
                        }
                        .foregroundStyle(Color.ckMutedForeground)
                    }
                }
            }

            CKProgressBar(value: progressValue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(Int(displayPercent)) percent remaining")
    }
}

// MARK: - Preview

#Preview("CKQuotaSection") {
    VStack(alignment: .leading, spacing: .ckLG) {
        Text("Quota Sections")
            .font(.ckTitle)

        VStack(spacing: .ckMD) {
            CKQuotaSection(
                title: "Claude Sonnet",
                remainingPercent: 85,
                resetTime: "2h"
            )

            CKQuotaSection(
                title: "Gemini Pro",
                remainingPercent: 45,
                resetTime: "1d"
            )

            CKQuotaSection(
                title: "GPT-4",
                remainingPercent: 15,
                resetTime: "3h"
            )

            CKQuotaSection(
                title: "Weekly Usage",
                remainingPercent: 60
            )
        }
    }
    .padding()
    .frame(width: 400)
    .background(Color.ckBackground)
}
