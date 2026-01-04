//
//  GLMAPIKeySheet.swift
//  Quotio
//
//  Simplified API key configuration sheet for GLM (BigModel.cn)
//  Reference design based on Gemini CLI configuration
//

import SwiftUI

struct GLMAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel

    let provider: CustomProvider?
    let onSave: (CustomProvider) -> Void

    // MARK: - Form State

    @State private var apiKey: String = ""
    @State private var endpoint: GLMEndpoint = .bigmodel

    @State private var validationError: String?
    @State private var showValidationAlert = false

    private var isEditing: Bool {
        provider != nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    apiKeySection
                    endpointSection
                }
                .padding(20)
            }

            Divider()

            footerView
        }
        .frame(width: 480, height: 320)
        .onAppear {
            loadProviderData()
        }
        .alert("glm.validationError".localized(), isPresented: $showValidationAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            if let error = validationError {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 16) {
            Image("glm")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "glm.edit".localized() : "glm.add".localized())
                    .font(.headline)

                Text("glm.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("glm.apiKey".localized())
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("glm.apiKeyHint".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SecureField("glm.apiKeyPlaceholder".localized(), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Endpoint Section

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("glm.endpoint".localized())
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("glm.endpointHint".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $endpoint) {
                    ForEach(GLMEndpoint.allCases) { ep in
                        Text(ep.displayName).tag(ep)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(true) // Only bigmodel.cn is supported
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            Button(isEditing ? "glm.saveChanges".localized() : "glm.addProvider".localized()) {
                saveProvider()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    // MARK: - Actions

    private func loadProviderData() {
        guard let provider = provider else { return }

        // Load API key from first entry
        if let firstKey = provider.apiKeys.first {
            apiKey = firstKey.apiKey
        }

        // Determine endpoint from base URL
        if provider.baseURL.contains("bigmodel.cn") {
            endpoint = .bigmodel
        }
    }

    private func saveProvider() {
        // Validate
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        if trimmedKey.isEmpty {
            validationError = "glm.error.emptyApiKey".localized()
            showValidationAlert = true
            return
        }

        // Build provider using GLM type (similar to Gemini compatibility)
        let newProvider = CustomProvider(
            id: provider?.id ?? UUID(),
            name: "GLM",
            type: .glmCompatibility,
            baseURL: endpoint.baseURL,
            apiKeys: [CustomAPIKeyEntry(apiKey: trimmedKey)],
            isEnabled: true,
            createdAt: provider?.createdAt ?? Date(),
            updatedAt: Date()
        )

        onSave(newProvider)
        dismiss()
    }
}

// MARK: - GLM Endpoint

enum GLMEndpoint: String, CaseIterable, Codable, Identifiable, Sendable {
    case bigmodel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bigmodel: return "bigmodel.cn"
        }
    }

    var baseURL: String {
        switch self {
        case .bigmodel: return "https://bigmodel.cn"
        }
    }
}

// MARK: - Preview

#Preview {
    GLMAPIKeySheet(provider: nil) { provider in
        print("Saved: \(provider.name)")
    }
}
