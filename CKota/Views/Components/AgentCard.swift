//
//  AgentCard.swift
//  CKota - Individual CLI agent card component
//

import SwiftUI

struct AgentCard: View {
    let status: AgentStatus
    let onConfigure: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Agent Icon
            ZStack {
                Circle()
                    .fill(status.agent.color.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: status.agent.systemIcon)
                    .font(.title2)
                    .foregroundStyle(status.agent.color)
            }

            // Agent Info
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

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if let docsURL = status.agent.docsURL {
                    Link(destination: docsURL) {
                        Image(systemName: "book")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("agents.viewDocs".localized())
                    .ckCursorPointer()
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
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(status.configured ? status.agent.color.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.statusColor)
                .frame(width: 6, height: 6)

            Text(status.statusText)
                .font(.caption)
                .foregroundStyle(status.statusColor)
        }
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
                agent: .claudeCode,
                installed: true,
                configured: false,
                binaryPath: "/opt/homebrew/bin/claude",
                version: nil,
                lastConfigured: nil
            ),
            onConfigure: {}
        )
    }
    .padding()
    .frame(width: 600)
}
