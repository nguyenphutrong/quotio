//
//  RingProgressView.swift
//  Quotio
//
//  Circular progress indicator for quota display
//

import QuotioApplication
import QuotioDomain
import SwiftUI

/// Circular progress indicator for quota display
struct RingProgressView: View {
    /// Percentage that means "no data available", matching the `-1` quota sentinel.
    nonisolated static let unknownPercent: Double = -1

    let percent: Double
    var size: CGFloat = 32
    var lineWidth: CGFloat = 4
    var tint: Color = .accentColor
    var showLabel: Bool = false

    /// A negative percentage is the "no data yet" sentinel. It must never be
    /// clamped into a real 0% reading, visually or for VoiceOver.
    nonisolated static func isUnknown(_ percent: Double) -> Bool {
        percent < 0
    }

    /// Center label text: the same `—` placeholder the text/card paths use when
    /// no data is available.
    nonisolated static func labelText(for percent: Double) -> String {
        isUnknown(percent) ? "—" : "\(Int(clamped(percent)))%"
    }

    /// VoiceOver value. Announces the shared "no usage data" string for unknown
    /// quotas instead of a fabricated "0 percent".
    static func accessibilityValueText(for percent: Double) -> String {
        isUnknown(percent)
            ? "quota.noDataYet".localized()
            : String(format: "%lld percent".localized(), Int64(clamped(percent)))
    }

    nonisolated private static func clamped(_ percent: Double) -> Double {
        min(100, max(0, percent))
    }

    private var isUnknown: Bool {
        Self.isUnknown(percent)
    }

    private var clamped: Double {
        Self.clamped(percent)
    }

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)

            // Progress ring — omitted when there is no data, so an unknown quota
            // is not drawn as a real 0% arc.
            if !isUnknown {
                Circle()
                    .trim(from: 0, to: clamped / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.3), value: clamped)
            }

            // Optional center label
            if showLabel {
                if isUnknown {
                    Text(Self.labelText(for: percent))
                        .font(.system(size: size * 0.24, weight: .bold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.labelText(for: percent))
                        .font(.system(size: size * 0.24, weight: .bold))
                        .monospacedDigit()
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("usage.ring".localized())
        .accessibilityValue(Self.accessibilityValueText(for: percent))
    }
}

#Preview {
    HStack(spacing: 20) {
        RingProgressView(percent: 75, tint: .green, showLabel: true)
        RingProgressView(percent: 30, tint: .yellow, showLabel: true)
        RingProgressView(percent: 5, tint: .red, showLabel: true)
        RingProgressView(percent: RingProgressView.unknownPercent, showLabel: true)
    }
    .padding()
}
