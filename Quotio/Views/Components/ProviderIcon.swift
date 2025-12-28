//
//  ProviderIcon.swift
//  Quotio
//

import SwiftUI
import AppKit

struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 24
    
    var body: some View {
        Group {
            if let nsImage = NSImage(named: provider.logoAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback to SF Symbol if image not found
                Image(systemName: provider.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.color)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(AIProvider.allCases) { provider in
            HStack {
                ProviderIcon(provider: provider, size: 32)
                Text(provider.displayName)
            }
        }
    }
    .padding()
}
