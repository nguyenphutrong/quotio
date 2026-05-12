//
//  AddCursorAccountSheet.swift
//  Quotio
//
//  Sheet for adding a Cursor account via Cursor's browser-based PKCE login
//  flow (see CursorOAuthService). The flow:
//
//   1. User clicks "Sign In with Cursor". We open
//      https://www.cursor.com/loginDeepControl?challenge=&uuid=&mode=login
//      in their default browser.
//   2. They sign in in the browser (possibly with a different Cursor account
//      than the one already in their IDE — this is the whole point).
//   3. We poll api2.cursor.sh/auth/poll until tokens come back, then save
//      them to CursorAccountStore.
//
//  A "Paste Tokens Manually" path is kept for advanced users.
//

import SwiftUI
import AppKit

struct AddCursorAccountSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let onDismiss: () -> Void

    private enum Phase: Equatable {
        case idle
        case polling
        case success(email: String)
        case error(String)
    }

    @State private var phase: Phase = .idle
    @State private var inFlight: CursorOAuthService.InFlightFlow?
    @State private var pollTask: Task<Void, Never>?
    @State private var copiedURL = false
    @State private var showManualEntry = false

    @State private var manualEmail = ""
    @State private var manualAccessToken = ""
    @State private var manualRefreshToken = ""
    @State private var manualError: String?
    @State private var isSavingManual = false

    private let oauthService = CursorOAuthService()

    private var isPolling: Bool {
        if case .polling = phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 24) {
            ProviderIcon(provider: .cursor, size: 64)

            VStack(spacing: 6) {
                Text("Connect Cursor")
                    .font(.title2).fontWeight(.bold)
                Text("Sign in to a Cursor account in your browser. You can repeat this to add multiple accounts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if showManualEntry {
                manualEntryForm
            } else {
                oauthBody
            }

            HStack(spacing: 12) {
                Button("action.cancel".localized(), role: .cancel) {
                    cancelAndClose()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(showManualEntry ? "Use Browser Sign-In" : "Paste Tokens Manually") {
                    if isPolling { pollTask?.cancel(); phase = .idle; inFlight = nil }
                    showManualEntry.toggle()
                    manualError = nil
                }
                .buttonStyle(.borderless)
                .disabled(isSavingManual)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(32)
        .frame(width: 520)
        .onDisappear {
            pollTask?.cancel()
        }
    }

    // MARK: - OAuth body

    @ViewBuilder
    private var oauthBody: some View {
        VStack(spacing: 16) {
            switch phase {
            case .idle:
                Button {
                    startOAuth()
                } label: {
                    Label("Sign In with Cursor", systemImage: "safari.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AIProvider.cursor.color)
                .controlSize(.large)

                Text("Your browser will open. Sign in to whichever Cursor account you want to add, then come back to this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            case .polling:
                pollingView

            case .success(let email):
                successView(email: email)

            case .error(let message):
                VStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        startOAuth()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AIProvider.cursor.color)
                }
            }
        }
    }

    @ViewBuilder
    private var pollingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Waiting for browser sign-in…")
                .font(.callout).fontWeight(.medium)

            if let url = inFlight?.loginURL {
                VStack(spacing: 6) {
                    Text("If the browser didn't open, use this link:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copiedURL = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedURL = false
                            }
                        } label: {
                            Label(copiedURL ? "Copied" : "Copy Link",
                                  systemImage: copiedURL ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AIProvider.cursor.color)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private func successView(email: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Connected")
                .font(.headline)
            Text(email)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Manual entry

    @ViewBuilder
    private var manualEntryForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Email").font(.caption).foregroundStyle(.secondary)
                TextField("you@example.com", text: $manualEmail)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Access Token").font(.caption).foregroundStyle(.secondary)
                SecureField("cursorAuth/accessToken", text: $manualAccessToken)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh Token (optional)").font(.caption).foregroundStyle(.secondary)
                SecureField("cursorAuth/refreshToken", text: $manualRefreshToken)
                    .textFieldStyle(.roundedBorder)
            }

            if let manualError {
                Text(manualError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await saveManual() }
            } label: {
                if isSavingManual {
                    SmallProgressView()
                } else {
                    Label("Save Account", systemImage: "plus.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AIProvider.cursor.color)
            .frame(maxWidth: .infinity)
            .disabled(isSavingManual || manualEmail.isEmpty || manualAccessToken.isEmpty)
        }
    }

    // MARK: - Actions

    private func startOAuth() {
        pollTask?.cancel()
        phase = .polling
        copiedURL = false

        let service = oauthService
        pollTask = Task {
            let flow = await service.startFlow()
            await MainActor.run { self.inFlight = flow }

            do {
                let result = try await service.waitForCompletion(flow: flow)
                let email = result.email ?? result.authId ?? "Cursor User"

                let ok = CursorAccountStore.shared.add(
                    email: email,
                    accessToken: result.accessToken,
                    refreshToken: result.refreshToken,
                    membershipType: nil
                )
                guard ok else {
                    await MainActor.run {
                        self.phase = .error("Couldn't save tokens to the keychain.")
                    }
                    return
                }

                await MainActor.run { self.phase = .success(email: email) }
                await viewModel.refreshQuotaForProvider(.cursor)

                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    if case .success = self.phase { self.onDismiss() }
                }
            } catch is CancellationError {
                // sheet dismissed, nothing to do
            } catch let error as CursorOAuthError {
                await MainActor.run {
                    self.phase = .error(error.errorDescription ?? "Sign-in failed.")
                }
            } catch {
                await MainActor.run {
                    self.phase = .error(error.localizedDescription)
                }
            }
        }
    }

    private func cancelAndClose() {
        pollTask?.cancel()
        onDismiss()
    }

    private func saveManual() async {
        isSavingManual = true
        defer { isSavingManual = false }
        manualError = nil

        let email = manualEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let access = manualAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = manualRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let ok = CursorAccountStore.shared.add(
            email: email,
            accessToken: access,
            refreshToken: refresh.isEmpty ? nil : refresh,
            membershipType: nil
        )
        if ok {
            await viewModel.refreshQuotaForProvider(.cursor)
            onDismiss()
        } else {
            manualError = "Couldn't save tokens. Check the email and access token."
        }
    }
}
