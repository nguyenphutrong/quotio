//
//  SidebarHeaderView.swift
//  CKota
//
//  Sidebar header component with app info
//

import SwiftUI

struct SidebarHeaderView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        HStack(spacing: 12) {
            // App Icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            } else {
                // Fallback placeholder
                Image(systemName: "server.rack")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.ckAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.ckAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("CKota")
                        .font(.headline)
                        .fontWeight(.bold)

                    Text("v\(appVersion)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.ckMutedForeground)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.ckMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text("AI Proxy Manager")
                    .font(.caption)
                    .foregroundStyle(Color.ckMutedForeground)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

#Preview {
    SidebarHeaderView()
}
