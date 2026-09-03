//
//  YubiKeyProvisioningSheet.swift
//  Quotio
//
//  Collects the PIV PIN once and provisions the Quotio identity in the
//  background, without leaving a Terminal window behind.
//

import QuotioApplication
import QuotioDomain
import SwiftUI

struct YubiKeyProvisioningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(YubiKeySettingsScreenModel.self) private var model

    let device: YubiKeyPIVDevice
    let onSuccess: @MainActor () async -> Void

    @State private var preflight: YubiKeyPIVPreflight?
    @State private var pin = ""
    @State private var managementKey = ""
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var failure: String?

    private var canStart: Bool {
        preflight != nil && !pin.isEmpty && acknowledged && !isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let preflight {
                        planView(preflight)
                        credentialsView(preflight)
                    } else if failure == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("yubikey.setup.inspecting".localized())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }

            Divider()

            footerView
        }
        .frame(width: 480, height: 560)
        .task { await loadPreflight() }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 26))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("yubikey.setup.title".localized())
                    .font(.headline)

                Text(device.name + " (" + device.serial + ")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    private func planView(_ preflight: YubiKeyPIVPreflight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("yubikey.setup.plan".localized())
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            switch preflight.slot9d {
            case .occupied:
                warningLabel("yubikey.setup.slotOccupied".localized())
            case .unknown:
                warningLabel("yubikey.setup.slotUnknown".localized())
            case .empty:
                Label("yubikey.setup.slotEmpty".localized(), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            warningLabel("yubikey.setup.managementKeyNote".localized())
        }
    }

    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func credentialsView(_ preflight: YubiKeyPIVPreflight) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("yubikey.setup.pin".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SecureField("yubikey.setup.pinPlaceholder".localized(), text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)

                if let tries = preflight.pinTriesRemaining {
                    Text(String(format: "yubikey.setup.pinTries".localized(), tries))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("yubikey.setup.pinNote".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Once the management key is protected by the PIN, ykman resolves it
            // from the key itself and never asks for it.
            if !preflight.managementKeyProtected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("yubikey.setup.managementKey".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    SecureField("yubikey.setup.managementKeyPlaceholder".localized(), text: $managementKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                }
            }

            Toggle(isOn: $acknowledged) {
                Text("yubikey.setup.acknowledge".localized())
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(isWorking)
        }
    }

    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) { dismiss() }
                .disabled(isWorking)

            Spacer()

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("yubikey.setup.working".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("yubikey.setup.start".localized()) {
                Task { await provision() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
        .padding(20)
    }

    /// - Parameter reportingFailure: false when refreshing after a failed
    ///   attempt, so a follow-up read cannot overwrite the error that matters.
    private func loadPreflight(reportingFailure: Bool = true) async {
        let result = await model.preflight(device)
        switch result {
        case let .success(state):
            preflight = state
        case let .failure(error):
            if reportingFailure { failure = error.message }
        }
    }

    private func provision() async {
        guard let preflight else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        let pin = pin
        let managementKey = managementKey.isEmpty ? nil : managementKey
        let result = await model.provision(
            device: device,
            preflight: preflight,
            pin: pin,
            managementKey: managementKey
        )

        switch result {
        case .success:
            self.pin = ""
            self.managementKey = ""
            await onSuccess()
            dismiss()
        case let .failure(error):
            failure = error.message
            // A rejected PIN costs an attempt; re-read the counter so the sheet
            // shows how many are left before the user retries.
            await loadPreflight(reportingFailure: false)
        }
    }
}

@MainActor
private extension YubiKeyProvisioningError {
    var message: String {
        switch self {
        case .toolMissing:
            "yubikey.error.toolMissing".localized()
        case .timedOut:
            "yubikey.error.timedOut".localized()
        case let .deviceUnavailable(detail):
            String(format: "yubikey.error.deviceUnavailable".localized(), detail)
        case .managementKeyRejected:
            "yubikey.error.managementKey".localized()
        case let .pinRejected(triesRemaining):
            if let triesRemaining {
                String(format: "yubikey.error.pinTries".localized(), triesRemaining)
            } else {
                "yubikey.error.pin".localized()
            }
        case .pinBlocked:
            "yubikey.error.pinBlocked".localized()
        case let .stepFailed(detail):
            String(format: "yubikey.error.step".localized(), detail)
        }
    }
}
