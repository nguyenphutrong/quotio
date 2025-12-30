//
//  ProviderIcon.swift
//  CKota
//

import SwiftUI

struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 24

    var body: some View {
        Image(provider.logoAssetName, bundle: .main)
            .resizable()
            .aspectRatio(contentMode: .fit)
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
