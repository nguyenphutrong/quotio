import SwiftUI
import QuotioDomain

struct CompanionSettingsSection: View {
    @Bindable var model: CompanionScreenModel
    @State private var deviceToRevoke: CompanionDevice?

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("companion.intro".localized(), systemImage: "iphone")
                        .font(.headline)
                    Text("companion.summary".localized()).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                        Button("companion.pair".localized()) { model.presentPairing(in: .settings) }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(.vertical, 6)
            }

            Section {
                if model.devices.isEmpty {
                    Text("companion.noDevices".localized()).foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.label).fontWeight(.medium)
                            Text("companion.readOnly".localized()).font(.caption).foregroundStyle(.secondary)
                            Text("\("companion.expires".localized()) \(device.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("companion.revoke".localized(), role: .destructive) { deviceToRevoke = device }
                            .disabled(model.busy)
                    }.padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("companion.devices".localized())
                    Text(String(model.devices.count)).foregroundStyle(.secondary)
                    Spacer()
                    RefreshButton(title: "action.refresh".localized(), isRefreshing: model.busy) { await model.reload() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }

            Section("companion.connection".localized()) {
                CompanionConnectionSetupView(model: model).disabled(model.busy)
                Toggle(statusTitle, isOn: Binding(
                    get: { model.enabled },
                    set: { enabled in Task { await model.configure(enabled: enabled) } }
                ))
                .disabled(model.busy || !model.hasLoaded || (!model.enabled && !model.canEnable))
                if model.enabled {
                    Label(connectionTitle, systemImage: model.mode == .tailscale ? "network" : model.mode == .localNetwork ? "wifi" : "lock.shield")
                    LabeledContent("companion.origin".localized()) {
                        Text(model.origin).font(.system(.body, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
                    }
                    Text("companion.disableHint".localized()).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let failure = model.failure {
                Section { Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .task { await model.reload() }
        .sheet(isPresented: Binding(
            get: { model.presentation == .settings },
            set: { if !$0 { model.hidePairing(in: .settings) } }
        )) {
            CompanionPairingView(model: model, presentation: .settings)
                .frame(width: 640)
        }
        .confirmationDialog("companion.revokeConfirm".localized(), isPresented: Binding(
            get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }
        ), titleVisibility: .visible) {
            Button("companion.revoke".localized(), role: .destructive) {
                if let device = deviceToRevoke { Task { await model.revoke(device.id) } }
                deviceToRevoke = nil
            }
            Button("action.cancel".localized(), role: .cancel) { deviceToRevoke = nil }
        } message: { Text(deviceToRevoke?.label ?? "") }
    }

    private var statusTitle: String {
        guard model.hasLoaded else { return "companion.statusUnknown".localized() }
        return (model.enabled ? "companion.statusOn" : "companion.statusOff").localized()
    }

    private var connectionTitle: String {
        switch model.mode {
        case .localNetwork: "companion.localNetwork".localized()
        case .tailscale: "companion.tailscale".localized()
        case .proxy: "companion.customHTTPS".localized()
        }
    }
}
