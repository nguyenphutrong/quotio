//
//  CKCard.swift
//  CKota
//
//  Card view modifier implementing CCS design system styling.
//

import SwiftUI

// MARK: - CKCard View Modifier

/// Card styling modifier with CCS design tokens.
/// Provides consistent card appearance with optional small variant.
/// Uses shadow for depth instead of border per mockup design.
struct CKCardStyle: ViewModifier {
    var isSmall: Bool = false

    func body(content: Content) -> some View {
        let radius = isSmall ? CKLayout.cardRadiusSM : CKLayout.cardRadius
        content
            .padding(isSmall ? CKLayout.cardPaddingSM : CKLayout.cardPadding)
            .background(Color.ckCard)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.ckBorder.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

extension View {
    /// Applies CKota card styling.
    /// - Parameter small: Use compact padding and smaller corner radius
    /// - Returns: Styled view
    func ckCard(small: Bool = false) -> some View {
        modifier(CKCardStyle(isSmall: small))
    }
}

// MARK: - Preview

#Preview("CKCard") {
    VStack(spacing: .ckMD) {
        VStack(alignment: .leading, spacing: .ckSM) {
            Text("Standard Card")
                .font(.ckHeadline)
            Text("This is a standard card with default padding.")
                .font(.ckBody)
                .foregroundStyle(Color.ckMutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ckCard()

        HStack(spacing: .ckMD) {
            VStack(alignment: .leading, spacing: .ckXS) {
                Text("Small Card")
                    .font(.ckHeadline)
                Text("Compact variant")
                    .font(.ckCallout)
                    .foregroundStyle(Color.ckMutedForeground)
            }
            .ckCard(small: true)

            VStack(alignment: .leading, spacing: .ckXS) {
                Text("Small Card 2")
                    .font(.ckHeadline)
                Text("Another compact")
                    .font(.ckCallout)
                    .foregroundStyle(Color.ckMutedForeground)
            }
            .ckCard(small: true)
        }
    }
    .padding()
    .background(Color.ckBackground)
}
