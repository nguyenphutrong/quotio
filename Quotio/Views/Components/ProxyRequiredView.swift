//
//  ProxyRequiredView.swift
//  Quotio - Unified "Proxy Not Running" view component
//

import SwiftUI

/// A unified view component shown when proxy is required but not running
struct ProxyRequiredView: View {
    let title: String
    let description: String
    let icon: String
    let onStartProxy: () async -> Void
    
    @State private var isStarting = false
    
    init(
        title: String? = nil,
        description: String? = nil,
        icon: String = "network.slash",
        onStartProxy: @escaping () async -> Void
    ) {
        self.title = title ?? "empty.proxyNotRunning".localized()
        self.description = description ?? "dashboard.startToBegin".localized()
        self.icon = icon
        self.onStartProxy = onStartProxy
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon with animated gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.15), .purple.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            // Text content
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            
            // Start button
            Button {
                isStarting = true
                Task {
                    await onStartProxy()
                    isStarting = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("action.startProxy".localized())
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
            .disabled(isStarting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview {
    ProxyRequiredView(
        description: "Start the proxy to manage API keys"
    ) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    .frame(width: 500, height: 400)
}
