//
//  ProviderIcon.swift
//  Quotio
//

import SwiftUI
import AppKit

struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 24
    var customName: String? = nil
    var customColor: Color? = nil
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var needsLightModeInDark: Bool {
        switch provider {
        case .cursor, .copilot:
            return true
        default:
            return false
        }
    }
    
    private var effectiveColor: Color {
        customColor ?? provider.color
    }
    
    private var initials: String {
        let name = customName ?? provider.displayName
        let words = name.split(separator: " ")
        
        if words.count >= 2 {
            let first = words[0].prefix(1)
            let second = words[1].prefix(1)
            return String(first + second).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
    
    var body: some View {
        Group {
            if let nsImage = ImageCacheService.shared.image(named: provider.logoAssetName, size: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .if(needsLightModeInDark && colorScheme == .dark) { view in
                        view.colorInvert()
                    }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
    }
    
    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(effectiveColor.opacity(0.15))
            
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(effectiveColor)
        }
    }
}

// MARK: - Custom Provider Icon

struct CustomProviderIcon: View {
    let name: String
    let color: Color
    var size: CGFloat = 24
    var assetName: String? = nil
    
    private var initials: String {
        let words = name.split(separator: " ")
        
        if words.count >= 2 {
            let first = words[0].prefix(1)
            let second = words[1].prefix(1)
            return String(first + second).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
    
    var body: some View {
        Group {
            if let assetName = assetName,
               let nsImage = ImageCacheService.shared.image(named: assetName, size: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                    
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                }
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

#Preview {
    VStack(spacing: 16) {
        ForEach(AIProvider.allCases) { provider in
            HStack {
                ProviderIcon(provider: provider, size: 32)
                Text(provider.displayName)
            }
        }
        
        Divider()
        
        CustomProviderIcon(name: "My Custom API", color: .purple, size: 32)
        CustomProviderIcon(name: "OpenRouter", color: .green, size: 32)
    }
    .padding()
}
