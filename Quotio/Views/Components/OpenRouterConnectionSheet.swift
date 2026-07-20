import SwiftUI

struct OpenRouterConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let account: MonitorAccount?
    let onSave: (String, String) async throws -> Void

    @State private var label = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var isEditing: Bool { account != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ProviderIcon(provider: .openRouter, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "openrouter.connection.edit".localized() : "openrouter.connection.title".localized())
                        .font(.headline)
                    Text("openrouter.connection.subtitle".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("customProviders.providerName".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("openrouter.label.placeholder".localized(), text: $label)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditing)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("openrouter.apiKey.label".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SecureField("openrouter.apiKey.placeholder".localized(), text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Text(isEditing ? "openrouter.apiKey.rotateHint".localized() : "openrouter.apiKey.hint".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(24)

            Divider()

            HStack {
                Button("action.cancel".localized()) { dismiss() }
                Spacer()
                Button(isEditing ? "action.save".localized() : "action.connect".localized()) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isSaving)
            }
            .padding(20)
        }
        .frame(width: 450, height: 360)
        .onAppear { label = account?.accountKey ?? "" }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(label, apiKey)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
