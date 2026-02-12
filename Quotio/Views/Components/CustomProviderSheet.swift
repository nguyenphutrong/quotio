//
//  CustomProviderSheet.swift
//  Quotio - Custom AI provider add/edit modal
//

import SwiftUI

struct CustomProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let provider: CustomProvider?
    let onSave: (CustomProvider) -> Void
    
    // MARK: - Form State
    
    @State private var name: String = ""
    @State private var providerType: CustomProviderType = .openaiCompatibility
    @State private var baseURL: String = ""
    @State private var prefix: String = ""
    @State private var apiKeys: [CustomAPIKeyEntry] = [CustomAPIKeyEntry(apiKey: "")]
    @State private var models: [ModelMapping] = []
    @State private var headers: [CustomHeader] = []
    @State private var isEnabled: Bool = true
    
    @State private var validationErrors: [String] = []
    @State private var showValidationAlert = false
    
    private var isEditing: Bool {
        provider != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    basicInfoSection
                    apiKeysSection
                    
                    if providerType.supportsModelMapping {
                        modelMappingSection
                    }
                    
                    if providerType.supportsCustomHeaders {
                        customHeadersSection
                    }
                    
                    enabledSection
                }
                .padding(20)
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 600, height: 700)
        .onAppear {
            loadProviderData()
        }
        .alert("customProviders.validationError".localized(), isPresented: $showValidationAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text(validationErrors.joined(separator: "\n"))
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            Image(providerType.menuBarIconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "customProviders.edit".localized() : "customProviders.add".localized())
                    .font(.headline)
                
                Text(providerType.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
    
    // MARK: - Basic Info Section
    
    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("customProviders.basicInfo".localized())
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("customProviders.providerName".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("e.g., OpenRouter, Ollama Local", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("customProviders.providerType".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Picker("Type", selection: $providerType) {
                    ForEach(CustomProviderType.allCases) { type in
                        HStack {
                            Image(type.menuBarIconName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                            Text(type.localizedDisplayName)
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: providerType) { _, newType in
                    // Update base URL to default if empty
                    if baseURL.isEmpty, let defaultURL = newType.defaultBaseURL {
                        baseURL = defaultURL
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("customProviders.baseURL".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if !providerType.requiresBaseURL, let defaultURL = providerType.defaultBaseURL {
                        Text("(default: \(defaultURL))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                TextField(providerType.defaultBaseURL ?? "https://api.example.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("customProviders.prefix".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("(\("customProviders.optional".localized()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                TextField("customProviders.prefixHint".localized(), text: $prefix)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - API Keys Section
    
    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("customProviders.apiKeys".localized())
                    .font(.headline)
                
                Spacer()
                
                Button {
                    apiKeys.append(CustomAPIKeyEntry(apiKey: ""))
                } label: {
                    Label("customProviders.addKey".localized(), systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.sectionHeader)
            }
            
            ForEach(Array(apiKeys.enumerated()), id: \.offset) { index, _ in
                apiKeyRow(index: index)
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func apiKeyRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API Key #\(index + 1)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if apiKeys.count > 1 {
                    Button {
                        apiKeys.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.rowActionDestructive)
                }
            }
            
            SecureField("customProviders.apiKeys".localized(), text: Binding(
                get: { apiKeys[safe: index]?.apiKey ?? "" },
                set: { if index < apiKeys.count { apiKeys[index].apiKey = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            
            TextField("customProviders.proxyURL".localized(), text: Binding(
                get: { apiKeys[safe: index]?.proxyURL ?? "" },
                set: { if index < apiKeys.count { apiKeys[index].proxyURL = $0.isEmpty ? nil : $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
        .padding(12)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(6)
    }
    
    // MARK: - Model Mapping Section
    
    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("customProviders.modelMapping".localized())
                        .font(.headline)
                    
                    Text("customProviders.modelMappingDesc".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    models.append(ModelMapping(name: "", alias: ""))
                } label: {
                    Label("customProviders.addMapping".localized(), systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.sectionHeader)
            }
            
            if models.isEmpty {
                Text("customProviders.noMappings".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(models.enumerated()), id: \.offset) { index, _ in
                    modelMappingRow(index: index)
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func modelMappingRow(index: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                TextField("customProviders.upstreamModel".localized(), text: Binding(
                    get: { models[safe: index]?.name ?? "" },
                    set: { if index < models.count { models[index].name = $0 } }
                ))
                .textFieldStyle(.roundedBorder)
                
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                
                TextField("customProviders.localAlias".localized(), text: Binding(
                    get: { models[safe: index]?.alias ?? "" },
                    set: { if index < models.count { models[index].alias = $0 } }
                ))
                .textFieldStyle(.roundedBorder)
                
                Button {
                    models.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.rowActionDestructive)
            }
            
            HStack(spacing: 8) {
                Text("customProviders.thinkingBudget".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                TextField("customProviders.thinkingBudgetHint".localized(), text: Binding(
                    get: { models[safe: index]?.thinkingBudget ?? "" },
                    set: { if index < models.count { models[index].thinkingBudget = $0.isEmpty ? nil : $0 } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                
                Spacer()
            }
            .padding(.leading, 4)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Custom Headers Section
    
    private var customHeadersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("customProviders.customHeaders".localized())
                        .font(.headline)
                    
                    Text("customProviders.customHeadersDesc".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    headers.append(CustomHeader(key: "", value: ""))
                } label: {
                    Label("customProviders.addHeader".localized(), systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.sectionHeader)
            }
            
            if headers.isEmpty {
                Text("customProviders.noHeaders".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, _ in
                    customHeaderRow(index: index)
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func customHeaderRow(index: Int) -> some View {
        HStack(spacing: 12) {
            TextField("customProviders.headerName".localized(), text: Binding(
                get: { headers[safe: index]?.key ?? "" },
                set: { if index < headers.count { headers[index].key = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            
            Text(":")
                .foregroundStyle(.secondary)
            
            TextField("customProviders.headerValue".localized(), text: Binding(
                get: { headers[safe: index]?.value ?? "" },
                set: { if index < headers.count { headers[index].value = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            
            Button {
                headers.remove(at: index)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.rowActionDestructive)
        }
    }
    
    // MARK: - Enabled Section
    
    private var enabledSection: some View {
        HStack {
            Toggle("customProviders.enableProvider".localized(), isOn: $isEnabled)
            
            Spacer()
            
            if !isEnabled {
                Text("customProviders.disabledNote".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            
            Button(isEditing ? "customProviders.saveChanges".localized() : "customProviders.addProvider".localized()) {
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
        
        name = provider.name
        providerType = provider.type
        baseURL = provider.baseURL
        prefix = provider.prefix ?? ""
        apiKeys = provider.apiKeys
        models = provider.models
        headers = provider.headers
        isEnabled = provider.isEnabled
    }
    
    private func saveProvider() {
        // Build provider
        let newProvider = CustomProvider(
            id: provider?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            type: providerType,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            prefix: prefix.trimmingCharacters(in: .whitespaces).isEmpty ? nil : prefix.trimmingCharacters(in: .whitespaces),
            apiKeys: apiKeys.filter { !$0.apiKey.trimmingCharacters(in: .whitespaces).isEmpty },
            models: models.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty },
            headers: headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty },
            isEnabled: isEnabled,
            createdAt: provider?.createdAt ?? Date(),
            updatedAt: Date()
        )
        
        // Validate
        validationErrors = CustomProviderService.shared.validateProvider(newProvider)
        
        if validationErrors.isEmpty {
            onSave(newProvider)
            dismiss()
        } else {
            showValidationAlert = true
        }
    }
}

// MARK: - Array Safe Subscript Extension

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

#Preview {
    CustomProviderSheet(provider: nil) { provider in
        print("Saved: \(provider.name)")
    }
}
