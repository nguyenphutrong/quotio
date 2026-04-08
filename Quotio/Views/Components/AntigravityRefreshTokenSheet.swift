//
//  AntigravityRefreshTokenSheet.swift
//  Quotio
//
//  Sheet for importing an Antigravity account via a Google OAuth refresh token.
//  Validates the token, exchanges it for an access token, and writes the auth file.
//

import SwiftUI

// MARK: - Sheet State

private enum SheetState {
    case enteringData
    case importing
    case success(email: String)
    case failed(message: String)
    case confirmOverwrite(email: String)
}

// MARK: - View

struct AntigravityRefreshTokenSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel

    let onDismiss: () -> Void

    @State private var email: String = ""
    @State private var refreshToken: String = ""
    @State private var isTokenVisible: Bool = false
    @State private var state: SheetState = .enteringData

    private var canImport: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            headerView
            Divider()
            contentView
            Divider()
            actionButtons
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: .antigravity, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("antigravity.import.refreshToken.title".localized())
                    .font(.headline)
                Text("antigravity.import.refreshToken.subtitle".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .enteringData:
            formContent
        case .importing:
            importingContent
        case .success(let email):
            successContent(email: email)
        case .failed(let message):
            failureContent(message: message)
        case .confirmOverwrite(let email):
            overwriteContent(email: email)
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Email field
            VStack(alignment: .leading, spacing: 4) {
                Text("antigravity.import.email.label".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "antigravity.import.email.placeholder".localized(),
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            }

            // Refresh token field
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("antigravity.import.refreshToken.label".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        isTokenVisible.toggle()
                    } label: {
                        Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Group {
                    if isTokenVisible {
                        TextField(
                            "antigravity.import.refreshToken.placeholder".localized(),
                            text: $refreshToken,
                            axis: .vertical
                        )
                    } else {
                        SecureField(
                            "antigravity.import.refreshToken.placeholder".localized(),
                            text: $refreshToken
                        )
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            }

            // Hint
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("antigravity.import.refreshToken.hint".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var importingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("antigravity.import.importing".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func successContent(email: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("antigravity.import.success".localized())
                .font(.headline)
                .foregroundStyle(.green)
            Text(email)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func failureContent(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("antigravity.import.failed".localized())
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func overwriteContent(email: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("antigravity.import.overwrite.title".localized())
                .font(.headline)
            Text(String(format: "antigravity.import.overwrite.message".localized(), email))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .enteringData:
            HStack {
                Button("action.cancel".localized()) {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("antigravity.import.action.import".localized()) {
                    Task { await performImport(overwrite: false) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
            }

        case .importing:
            EmptyView()

        case .success:
            Button("action.done".localized()) {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

        case .failed:
            HStack {
                Button("action.cancel".localized()) {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("action.retry".localized()) {
                    state = .enteringData
                }
                .buttonStyle(.borderedProminent)
            }

        case .confirmOverwrite(let email):
            HStack {
                Button("action.cancel".localized()) {
                    state = .enteringData
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("antigravity.import.overwrite.confirm".localized()) {
                    Task { await performImport(overwrite: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }

    // MARK: - Actions

    private func performImport(overwrite: Bool) async {
        state = .importing
        do {
            try await viewModel.importAntigravityRefreshToken(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                refreshToken: refreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
                overwrite: overwrite
            )
            state = .success(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let importError as AntigravityRefreshTokenImportService.ImportError {
            if case .accountAlreadyExists(let existingEmail) = importError {
                state = .confirmOverwrite(email: existingEmail)
            } else {
                state = .failed(message: importError.localizedDescription)
            }
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }
}

// MARK: - Preview

#Preview {
    AntigravityRefreshTokenSheet(onDismiss: {})
        .environment(QuotaViewModel())
}
