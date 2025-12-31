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
        .alert("Validation Error", isPresented: $showValidationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationErrors.joined(separator: "\n"))
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(providerType.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: providerType.iconName)
                    .font(.title3)
                    .foregroundStyle(providerType.color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Custom Provider" : "Add Custom Provider")
                    .font(.headline)
                
                Text(providerType.description)
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
            Text("Basic Information")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("e.g., OpenRouter, Ollama Local", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider Type")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Picker("Type", selection: $providerType) {
                    ForEach(CustomProviderType.allCases) { type in
                        HStack {
                            Image(systemName: type.iconName)
                            Text(type.displayName)
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
                    Text("Base URL")
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
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - API Keys Section
    
    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("API Keys")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    apiKeys.append(CustomAPIKeyEntry(apiKey: ""))
                } label: {
                    Label("Add Key", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
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
                    .buttonStyle(.borderless)
                }
            }
            
            SecureField("API Key", text: Binding(
                get: { apiKeys[safe: index]?.apiKey ?? "" },
                set: { if index < apiKeys.count { apiKeys[index].apiKey = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            
            TextField("Proxy URL (optional)", text: Binding(
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
                    Text("Model Mapping")
                        .font(.headline)
                    
                    Text("Map upstream model names to local aliases")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    models.append(ModelMapping(name: "", alias: ""))
                } label: {
                    Label("Add Mapping", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            if models.isEmpty {
                Text("No model mappings configured. Models will use their original names.")
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
        HStack(spacing: 12) {
            TextField("Upstream Model", text: Binding(
                get: { models[safe: index]?.name ?? "" },
                set: { if index < models.count { models[index].name = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            
            TextField("Local Alias", text: Binding(
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
            .buttonStyle(.borderless)
        }
    }
    
    // MARK: - Custom Headers Section
    
    private var customHeadersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Headers")
                        .font(.headline)
                    
                    Text("Add custom HTTP headers for API requests")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    headers.append(CustomHeader(key: "", value: ""))
                } label: {
                    Label("Add Header", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            if headers.isEmpty {
                Text("No custom headers configured.")
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
            TextField("Header Name", text: Binding(
                get: { headers[safe: index]?.key ?? "" },
                set: { if index < headers.count { headers[index].key = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            
            Text(":")
                .foregroundStyle(.secondary)
            
            TextField("Header Value", text: Binding(
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
            .buttonStyle(.borderless)
        }
    }
    
    // MARK: - Enabled Section
    
    private var enabledSection: some View {
        HStack {
            Toggle("Enable this provider", isOn: $isEnabled)
            
            Spacer()
            
            if !isEnabled {
                Text("Disabled providers are not included in the proxy configuration")
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
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)
            
            Spacer()
            
            Button(isEditing ? "Save Changes" : "Add Provider") {
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
