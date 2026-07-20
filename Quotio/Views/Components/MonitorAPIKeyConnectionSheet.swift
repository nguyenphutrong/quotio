import SwiftUI

struct MonitorAPIKeyConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let provider: AIProvider
    let account: MonitorAccount?
    let onSave: (String, String) async throws -> Void

    @State private var label = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var isEditing: Bool { account != nil }
    private var localizationPrefix: String {
        provider == .factoryDroid ? "factory" : "openrouter"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ProviderIcon(provider: provider, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(isEditing ? "connection.edit" : "connection.title"))
                        .font(.headline)
                    Text(localized("connection.subtitle"))
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
                    TextField(localized("label.placeholder"), text: $label)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditing)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("apiKey.label"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SecureField(localized("apiKey.placeholder"), text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Text(localized(isEditing ? "apiKey.rotateHint" : "apiKey.hint"))
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

    private func localized(_ suffix: String) -> String {
        (localizationPrefix + "." + suffix).localized()
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
