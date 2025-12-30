//
//  CKKPICard.swift
//  CKota
//
//  KPI metric card for dashboard display.
//  Shows icon, label, and value with customizable colors.
//

import SwiftUI

// MARK: - CKKPICard

/// Dashboard KPI metric card with icon and value display.
struct CKKPICard: View {
    let icon: String
    let label: String
    let value: String

    var subtitle: String?
    var valueColor: Color = .ckForeground
    var iconBackgroundColor: Color = .ckAccentLight
    var iconColor: Color = .ckAccent
    var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: .ckSM) {
            // Icon and label row
            HStack(spacing: .ckSM) {
                Image(systemName: icon)
                    .font(.system(size: CKLayout.iconSizeSM))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(iconBackgroundColor)
                    )

                Text(label)
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            // Value
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(valueColor)

            // Optional subtitle
            if let subtitle {
                Text(subtitle)
                    .font(.ckCallout)
                    .foregroundStyle(Color.ckMutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ckCard(small: true)
        .modifier(isLoading ? AnyViewModifier(ShimmerAnimation()) : AnyViewModifier(CKEmptyModifier()))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLoading ? "Loading \(label)" : "\(label): \(value)")
    }
}

/// Empty modifier for conditional application
struct CKEmptyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

/// Type-erased view modifier for conditional modifier application
struct AnyViewModifier: ViewModifier {
    private let transform: (AnyView) -> AnyView

    init(_ modifier: some ViewModifier) {
        self.transform = { view in
            AnyView(view.modifier(modifier))
        }
    }

    func body(content: Content) -> some View {
        transform(AnyView(content))
    }
}

// MARK: - Convenience Initializers

extension CKKPICard {
    /// Create with semantic color based on value
    init(
        icon: String,
        label: String,
        value: String,
        subtitle: String? = nil,
        status: CKStatusDot.Status
    ) {
        self.init(
            icon: icon,
            label: label,
            value: value,
            subtitle: subtitle,
            valueColor: status.color,
            iconBackgroundColor: status.color.opacity(0.1),
            iconColor: status.color
        )
    }
}

// MARK: - Preview

#Preview("CKKPICard") {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: .ckMD)], spacing: .ckMD) {
        CKKPICard(
            icon: "person.2.fill",
            label: "Accounts",
            value: "12",
            subtitle: "8 ready"
        )

        CKKPICard(
            icon: "arrow.up.arrow.down",
            label: "Requests",
            value: "1,234",
            iconBackgroundColor: Color.ckSuccess.opacity(0.1),
            iconColor: .ckSuccess
        )

        CKKPICard(
            icon: "text.word.spacing",
            label: "Tokens",
            value: "2.5M",
            subtitle: "processed",
            iconBackgroundColor: Color.purple.opacity(0.1),
            iconColor: .purple
        )

        CKKPICard(
            icon: "checkmark.circle.fill",
            label: "Success Rate",
            value: "98%",
            subtitle: "2 failed",
            status: .ready
        )

        CKKPICard(
            icon: "exclamationmark.triangle.fill",
            label: "Low Quota",
            value: "15%",
            subtitle: "needs attention",
            status: .exhausted
        )
    }
    .padding()
    .background(Color.ckBackground)
}
