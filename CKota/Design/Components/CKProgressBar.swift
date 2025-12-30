//
//  CKProgressBar.swift
//  CKota
//
//  Progress bar with threshold-based color coding.
//  Red (<20%), orange (20-35%), green (>35%).
//

import SwiftUI

// MARK: - CKProgressBar

/// Progress bar with automatic threshold-based coloring.
struct CKProgressBar: View {
    /// Progress value from 0.0 to 1.0
    let value: Double
    var height: CGFloat = CKLayout.progressBarHeight
    var showPercentage: Bool = false

    /// Color based on value thresholds
    private var barColor: Color {
        switch value {
        case 0 ..< 0.20: .ckDestructive
        case 0.20 ..< 0.35: .ckWarning
        default: .ckSuccess
        }
    }

    /// Clamped value for rendering
    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        HStack(spacing: .ckSM) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(Color.ckMuted)

                    // Progress fill
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(barColor)
                        .frame(width: geometry.size.width * clampedValue)
                        .animation(.ckStandard, value: value)
                }
            }
            .frame(height: height)

            if showPercentage {
                Text("\(Int(clampedValue * 100))%")
                    .font(.ckCallout)
                    .foregroundStyle(barColor)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(clampedValue * 100)) percent remaining")
    }
}

// MARK: - Compact Variant

extension CKProgressBar {
    /// Small height variant for dense layouts
    static func small(value: Double, showPercentage: Bool = false) -> CKProgressBar {
        CKProgressBar(value: value, height: CKLayout.progressBarHeightSM, showPercentage: showPercentage)
    }
}

// MARK: - Preview

#Preview("CKProgressBar") {
    VStack(alignment: .leading, spacing: .ckLG) {
        Text("Progress Bars")
            .font(.ckTitle)

        VStack(alignment: .leading, spacing: .ckMD) {
            Text("Standard Height")
                .font(.ckHeadline)

            CKProgressBar(value: 0.85)
            CKProgressBar(value: 0.45)
            CKProgressBar(value: 0.25)
            CKProgressBar(value: 0.10)
        }

        Divider()

        VStack(alignment: .leading, spacing: .ckMD) {
            Text("With Percentage")
                .font(.ckHeadline)

            CKProgressBar(value: 0.75, showPercentage: true)
            CKProgressBar(value: 0.30, showPercentage: true)
            CKProgressBar(value: 0.15, showPercentage: true)
        }

        Divider()

        VStack(alignment: .leading, spacing: .ckMD) {
            Text("Small Variant")
                .font(.ckHeadline)

            CKProgressBar.small(value: 0.60, showPercentage: true)
            CKProgressBar.small(value: 0.22, showPercentage: true)
        }
    }
    .padding()
    .frame(width: 300)
    .background(Color.ckBackground)
}
