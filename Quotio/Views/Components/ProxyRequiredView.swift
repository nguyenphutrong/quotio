//
//  ProxyRequiredView.swift
//  Quotio - Unified local proxy recovery view component
//

import SwiftUI

/// A unified view component shown while the local proxy is starting or needs recovery.
struct ProxyRequiredView: View {
    let title: String
    let description: String
    let icon: String
    let onRestartProxy: () async -> Void
    
    @State private var isStarting = false
    @State private var hasRequestedStart = false
    
    init(
        title: String? = nil,
        description: String? = nil,
        icon: String = "network.slash",
        onRestartProxy: @escaping () async -> Void
    ) {
        self.title = title ?? "empty.proxyNotRunning".localized()
        self.description = description ?? "dashboard.startToBegin".localized()
        self.icon = icon
        self.onRestartProxy = onRestartProxy
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
            
            // Recovery button
            Button {
                isStarting = true
                Task {
                    await onRestartProxy()
                    isStarting = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isStarting {
                        SmallProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("action.restartProxy".localized())
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
        .task {
            guard !hasRequestedStart else { return }
            hasRequestedStart = true
            isStarting = true
            await onRestartProxy()
            isStarting = false
        }
    }
}

#Preview {
    ProxyRequiredView(
        description: "cpa-plusplus is starting so API keys can be managed."
    ) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    .frame(width: 500, height: 400)
}
