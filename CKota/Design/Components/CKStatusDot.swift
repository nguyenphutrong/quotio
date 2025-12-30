//
//  CKStatusDot.swift
//  CKota
//
//  Multi-cue status indicator with color, icon, and label.
//  Supports pulse animation for live status and respects accessibility.
//

import SwiftUI

// MARK: - CKStatusDot

/// Multi-cue status indicator providing color + icon + text for accessibility.
struct CKStatusDot: View {
    enum Status: String, CaseIterable {
        case ready
        case cooling
        case exhausted
        case unknown

        var color: Color {
            switch self {
            case .ready: .ckSuccess
            case .cooling: .ckWarning
            case .exhausted: .ckDestructive
            case .unknown: Color.ckMutedForeground
            }
        }

        var icon: String {
            switch self {
            case .ready: "checkmark.circle.fill"
            case .cooling: "clock.fill"
            case .exhausted: "exclamationmark.circle.fill"
            case .unknown: "questionmark.circle"
            }
        }

        var label: String {
            switch self {
            case .ready: "Ready"
            case .cooling: "Cooling"
            case .exhausted: "Exhausted"
            case .unknown: "Unknown"
            }
        }
    }

    let status: Status
    var showLabel: Bool = true
    var showIcon: Bool = false
    var showPulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: .ckXS) {
            ZStack {
                // Pulse animation ring (only for ready status with pulse enabled)
                if showPulse, status == .ready, !reduceMotion {
                    Circle()
                        .fill(status.color.opacity(0.3))
                        .frame(width: CKLayout.statusDotSize * 2, height: CKLayout.statusDotSize * 2)
                        .modifier(PulseAnimation())
                }

                // Status dot
                Circle()
                    .fill(status.color)
                    .frame(width: CKLayout.statusDotSize, height: CKLayout.statusDotSize)
            }

            if showIcon {
                Image(systemName: status.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(status.color)
            }

            if showLabel {
                Text(status.label)
                    .font(.ckCallout)
                    .foregroundStyle(status.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(status == .ready ? .updatesFrequently : [])
    }

    private var accessibilityDescription: String {
        switch status {
        case .ready: "Status: Ready, account available"
        case .cooling: "Status: Cooling down, temporarily unavailable"
        case .exhausted: "Status: Quota exhausted"
        case .unknown: "Status: Unknown"
        }
    }
}

// MARK: - Convenience Initializers

extension CKStatusDot {
    /// Create status from string (matches AuthFile status values)
    init(from statusString: String, showLabel: Bool = true, showPulse: Bool = false) {
        let status: Status = switch statusString.lowercased() {
        case "ready": .ready
        case "cooling": .cooling
        case "error", "exhausted": .exhausted
        default: .unknown
        }
        self.init(status: status, showLabel: showLabel, showPulse: showPulse)
    }
}

// MARK: - Preview

#Preview("CKStatusDot") {
    VStack(alignment: .leading, spacing: .ckLG) {
        Text("Status Indicators")
            .font(.ckTitle)

        VStack(alignment: .leading, spacing: .ckMD) {
            ForEach(CKStatusDot.Status.allCases, id: \.self) { status in
                HStack(spacing: .ckLG) {
                    CKStatusDot(status: status)
                    CKStatusDot(status: status, showLabel: false)
                    CKStatusDot(status: status, showIcon: true)
                    CKStatusDot(status: status, showLabel: true, showIcon: true, showPulse: status == .ready)
                }
            }
        }

        Divider()

        Text("From String")
            .font(.ckHeadline)

        HStack(spacing: .ckMD) {
            CKStatusDot(from: "ready")
            CKStatusDot(from: "cooling")
            CKStatusDot(from: "error")
            CKStatusDot(from: "invalid")
        }
    }
    .padding()
    .background(Color.ckBackground)
}
