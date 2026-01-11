//
//  ExperimentalBadge.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Small badge indicating experimental/unstable features
//

import SwiftUI

/// Compact badge for marking experimental features
struct ExperimentalBadge: View {
    var body: some View {
        Text("badge.experimental".localized())
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(.orange.gradient)
            )
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack {
            Text("Feature Name")
            ExperimentalBadge()
        }
        
        HStack {
            Text("Another Feature")
                .fontWeight(.medium)
            ExperimentalBadge()
        }
    }
    .padding()
}
