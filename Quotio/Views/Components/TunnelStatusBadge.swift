//
//  TunnelStatusBadge.swift
//  Quotio - Compact tunnel status indicator
//

import SwiftUI

struct TunnelStatusBadge: View {
    let status: CloudflareTunnelStatus
    let compact: Bool
    
    init(status: CloudflareTunnelStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }
    
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if status == .starting || status == .stopping {
                    Circle()
                        .stroke(status.color.opacity(0.3), lineWidth: 2)
                        .frame(width: 8, height: 8)
                    
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(status.color, lineWidth: 2)
                        .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
                        .frame(width: 8, height: 8)
                        .onAppear {
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                isAnimating = true
                            }
                        }
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                    
                    if status == .active {
                        Circle()
                            .stroke(status.color.opacity(0.3), lineWidth: 2)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .frame(width: 12, height: 12)
            
            if !compact {
                Text(status.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background(status.color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(status.color.opacity(0.2), lineWidth: 0.5)
        )
    }
}

#Preview {
    VStack(spacing: 8) {
        TunnelStatusBadge(status: .idle)
        TunnelStatusBadge(status: .starting)
        TunnelStatusBadge(status: .active)
        TunnelStatusBadge(status: .stopping)
        TunnelStatusBadge(status: .error)
        
        Divider()
        
        TunnelStatusBadge(status: .active, compact: true)
    }
    .padding()
}
