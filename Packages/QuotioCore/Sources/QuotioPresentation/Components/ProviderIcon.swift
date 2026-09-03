//
//  ProviderIcon.swift
//  Quotio
//

import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI

struct ProviderIcon: View {
    let provider: QuotaProvider
    var size: CGFloat = 24
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ProviderImageScreenModel.self) private var imageModel
    
    /// Providers that need white icons in dark mode (have dark/black logos)
    private var needsLightModeInDark: Bool {
        switch provider {
        case .cursor, .copilot, .clinePass:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        Group {
            if let nsImage = imageModel.image(named: provider.logoAssetName, size: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .if(needsLightModeInDark && colorScheme == .dark) { view in
                        view.colorInvert()
                    }
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

// MARK: - View Extension for Conditional Modifier

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Symbol Effect Transition Modifier (macOS 15+ compatibility)

/// A ViewModifier that applies `.contentTransition(.symbolEffect(.replace))` on macOS 15+
/// and gracefully degrades on earlier versions.
struct SymbolEffectTransitionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(QuotaProvider.allCases) { provider in
            HStack {
                ProviderIcon(provider: provider, size: 32)
                Text(provider.displayName)
            }
        }
    }
    .padding()
}
