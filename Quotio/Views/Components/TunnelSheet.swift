//
//  TunnelSheet.swift
//  Quotio - Cloudflare Tunnel Configuration Sheet
//
//  Improved UI/UX
//

import SwiftUI
import AppKit

struct TunnelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel
    
    private var tunnelManager: TunnelManager { TunnelManager.shared }
    private var proxyPort: UInt16 { viewModel.daemonProxyService.port }
    
    @State private var isHoveringCopy = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
                .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 24) {
                    if !tunnelManager.installation.isInstalled {
                        installationBanner
                    } else {
                        statusSection
                        
                        if tunnelManager.tunnelState.isActive {
                            publicUrlSection
                        }
                        
                        if let error = tunnelManager.tunnelState.errorMessage {
                            errorSection(error)
                        }
                        
                        infoSection
                    }
                }
                .padding(24)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            footerView
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 520, height: 450)
    }
    
    // MARK: - Components
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.15), .purple.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                
                Image(systemName: "globe")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("tunnel.title".localized())
                    .font(.system(size: 18, weight: .semibold))
                
                Text("tunnel.subtitle".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(20)
    }
    
    private var statusSection: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("tunnel.status".localized())
                        .font(.headline)
                    
                    Text("localhost:" + String(proxyPort))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                
                Spacer()
                
                TunnelStatusBadge(status: tunnelManager.tunnelState.status)
            }
            .padding(16)
            
            Divider()
            
            HStack {
                Text(tunnelManager.tunnelState.isActive ? "tunnel.status.description.active".localized() : "tunnel.status.description.inactive".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    Task {
                        await tunnelManager.toggle(port: proxyPort)
                    }
                } label: {
                    Text(tunnelManager.tunnelState.isActive || tunnelManager.tunnelState.status == .starting
                         ? "tunnel.action.stop".localized()
                         : "tunnel.action.start".localized())
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(tunnelManager.tunnelState.isActive ? .red : .blue)
                .disabled(tunnelManager.tunnelState.isTransitioning)
                .controlSize(.regular)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
    
    private var publicUrlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("tunnel.publicURL".localized(), systemImage: "link")
                .font(.headline)
                .foregroundStyle(.primary)
            
            HStack(spacing: 12) {
                Text(tunnelManager.tunnelState.publicURL ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                
                Spacer()
                
                Button {
                    tunnelManager.copyURLToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help("action.copy".localized())
            }
            .padding(12)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
            )
            
            if let startTime = tunnelManager.tunnelState.startTime {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(String(format: "tunnel.uptime".localized(), formatUptime(since: startTime)))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
    
    private func errorSection(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("tunnel.error.title".localized())
                    .font(.headline)
                    .foregroundStyle(.red)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color.red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
        )
    }
    
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("tunnel.info.title".localized(), systemImage: "info.circle")
                .font(.headline)
            
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                        .frame(width: 20)
                    Text("tunnel.info.quick".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                GridRow {
                    Image(systemName: "clock")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                    Text("tunnel.info.temporary".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                GridRow {
                    Image(systemName: "person.badge.minus")
                        .foregroundStyle(.gray)
                        .frame(width: 20)
                    Text("tunnel.info.noAccount".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
    
    private var installationBanner: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .padding(.bottom, 8)
            
            VStack(spacing: 6) {
                Text("tunnel.notInstalled.title".localized())
                    .font(.title3)
                    .fontWeight(.bold)
                
                Text("tunnel.notInstalled.message".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                HStack {
                    Text("brew install cloudflared")
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                    
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install cloudflared", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                
                Link(destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")!) {
                    Text("tunnel.install.docs".localized())
                        .font(.footnote)
                        .underline()
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding()
    }
    
    private var footerView: some View {
        HStack {
            if tunnelManager.installation.isInstalled {
                if let version = tunnelManager.installation.version {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("cloudflared v" + version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                }
            }
            
            Spacer()
            
            Button("action.close".localized()) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)
        }
        .padding(20)
    }
    
    private func formatUptime(since date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    TunnelSheet()
        .environment(QuotaViewModel())
        .frame(width: 520, height: 450)
}
