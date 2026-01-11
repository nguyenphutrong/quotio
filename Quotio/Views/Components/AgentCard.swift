//
//  AgentCard.swift
//  Quotio
//

import SwiftUI

struct AgentCard: View {
    let status: AgentStatus
    let onConfigure: () -> Void
    
    @State private var isHovered = false
    
    private var borderColor: Color {
        if status.configured {
            return status.agent.color.opacity(0.4)
        } else if status.installed {
            return Color.orange.opacity(0.4)
        }
        return Color.clear
    }
    
    private var backgroundGradient: LinearGradient {
        if status.configured && isHovered {
            return LinearGradient(
                colors: [status.agent.color.opacity(0.08), status.agent.color.opacity(0.02)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(colors: [Color.clear], startPoint: .leading, endPoint: .trailing)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            agentIconView
            agentInfoView
            Spacer()
            actionsView
        }
        .padding(16)
        .background(
            ZStack {
                Color(.controlBackgroundColor)
                backgroundGradient
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .shadow(color: isHovered ? Color.black.opacity(0.08) : Color.clear, radius: 8, y: 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
    
    // MARK: - Agent Icon
    
    private var agentIconView: some View {
        ZStack {
            Circle()
                .fill(status.agent.color.opacity(0.15))
                .frame(width: 48, height: 48)
            
            Image(systemName: status.agent.systemIcon)
                .font(.title2)
                .foregroundStyle(status.agent.color)
        }
    }
    
    // MARK: - Agent Info
    
    private var agentInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(status.agent.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                StatusBadge(status: status)
            }
            
            Text(status.agent.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            
            if let path = status.binaryPath {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
    
    // MARK: - Actions (slide-in on hover)
    
    private var actionsView: some View {
        HStack(spacing: 8) {
            if let docsURL = status.agent.docsURL {
                Link(destination: docsURL) {
                    Image(systemName: "book")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("agents.viewDocs".localized())
                .opacity(isHovered ? 1 : 0)
                .offset(x: isHovered ? 0 : 20)
            }
            
            Button {
                onConfigure()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: status.configured ? "arrow.triangle.2.circlepath" : "gearshape")
                    Text(status.configured ? "agents.reconfigure".localized() : "agents.configure".localized())
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .tint(status.agent.color)
            .scaleEffect(isHovered ? 1.0 : 0.95)
            .opacity(isHovered ? 1 : 0.8)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: AgentStatus
    
    private var icon: String {
        if status.configured {
            return "checkmark.circle.fill"
        } else if status.installed {
            return "exclamationmark.circle.fill"
        }
        return "circle"
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            
            Text(status.statusText)
                .font(.caption)
        }
        .foregroundStyle(status.statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.statusColor.opacity(0.1))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 16) {
        AgentCard(
            status: AgentStatus(
                agent: .claudeCode,
                installed: true,
                configured: true,
                binaryPath: "/usr/local/bin/claude",
                version: "1.0.0",
                lastConfigured: Date()
            ),
            onConfigure: {}
        )
        
        AgentCard(
            status: AgentStatus(
                agent: .geminiCLI,
                installed: true,
                configured: false,
                binaryPath: "/opt/homebrew/bin/gemini",
                version: nil,
                lastConfigured: nil
            ),
            onConfigure: {}
        )
        
        AgentCard(
            status: AgentStatus(
                agent: .openCode,
                installed: true,
                configured: false,
                binaryPath: nil,
                version: nil,
                lastConfigured: nil
            ),
            onConfigure: {}
        )
    }
    .padding()
    .frame(width: 600)
}
