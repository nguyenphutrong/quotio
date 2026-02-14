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
    @State private var isTestingConnection = false
    @State private var testError: String?
    
    // Model fetching state
    @State private var availableModels: [AvailableModel] = []
    @State private var selectedModelIds: Set<String> = []
    @State private var modelSearchText: String = ""
    @State private var isLoadingModels: Bool = false
    @State private var modelFetchError: String?
    @State private var limitToSelectedModels: Bool = true
    
    private var isEditing: Bool {
        provider != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step 1: Provider name and type
                    basicInfoSection
                    
                    // Step 2: API Keys (needed before fetching models)
                    apiKeysSection
                    
                    // Step 3: Model selection (requires API key to fetch)
                    if providerType.supportsModelMapping {
                        modelMappingSection
                    }
                    
                    // Step 4: Custom headers (optional)
                    if providerType.supportsCustomHeaders {
                        customHeadersSection
                    }
                    
                    // Step 5: Enable toggle
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
            Button("action.ok".localized(), role: .cancel) {
                testError = nil
            }
        } message: {
            if let error = testError {
                Text(error)
            } else {
                Text(validationErrors.joined(separator: "\n"))
            }
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
            HStack {
                Text("customProviders.basicInfo".localized())
                    .font(.headline)
                Text("• Step 1")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
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
                Text("• Step 2")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
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
    
    private var filteredModels: [AvailableModel] {
        if modelSearchText.isEmpty {
            return availableModels
        }
        return availableModels.filter { 
            $0.name.localizedCaseInsensitiveContains(modelSearchText) ||
            $0.id.localizedCaseInsensitiveContains(modelSearchText)
        }
    }
    
    private var topModels: [AvailableModel] {
        // Return top 5 most popular models
        let popularModelIds = [
            "gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo", "claude-3-opus", "claude-3-sonnet",
            "claude-3-haiku", "claude-3-5-sonnet", "gemini-pro", "gemini-1.5-pro", "llama-3"
        ]
        return availableModels.filter { model in
            popularModelIds.contains { popularId in
                model.name.lowercased().contains(popularId.lowercased()) || 
                model.id.lowercased().contains(popularId.lowercased())
            }
        }
    }
    
    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("customProviders.modelMapping".localized())
                            .font(.headline)
                        Text("• Step 3")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Text("customProviders.modelMappingDesc".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if isLoadingModels {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button {
                        fetchModelsFromAPI()
                    } label: {
                        Label("customProviders.fetchModels".localized(), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.sectionHeader)
                    .disabled(apiKeys.first?.apiKey.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                }
            }
            
            // Limit models toggle
            if !availableModels.isEmpty {
                Toggle(isOn: $limitToSelectedModels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("customProviders.limitModels".localized())
                            .font(.subheadline)
                        Text("customProviders.limitModelsDesc".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                
                if limitToSelectedModels && selectedModelIds.isEmpty {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("customProviders.selectModelsHint".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Show fetch error if any
            if let error = modelFetchError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Model selection interface
            if !availableModels.isEmpty {
                modelSelectionList
            } else if !isLoadingModels {
                // Manual entry fallback
                manualModelEntry
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private var modelSelectionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search box
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("customProviders.searchModels".localized(), text: $modelSearchText)
                    .textFieldStyle(.plain)
                if !modelSearchText.isEmpty {
                    Button {
                        modelSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(.windowBackgroundColor))
            .cornerRadius(6)
            
            // Top 5 popular models
            if modelSearchText.isEmpty && !topModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("customProviders.popularModels".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    ForEach(topModels.prefix(5)) { model in
                        modelSelectionRow(model: model)
                    }
                }
            }
            
            // All models (searchable)
            if !modelSearchText.isEmpty || topModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if modelSearchText.isEmpty {
                        Text("customProviders.allModels".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredModels) { model in
                                modelSelectionRow(model: model)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            
            // Selected models count and actions
            if !selectedModelIds.isEmpty {
                HStack {
                    Text(String(format: "customProviders.selectedModels".localized(), selectedModelIds.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("customProviders.clearSelection".localized()) {
                        selectedModelIds.removeAll()
                    }
                    .font(.caption)
                }
            }
            
            // Select All / Deselect All buttons
            if !availableModels.isEmpty {
                HStack {
                    Button("customProviders.selectAll".localized()) {
                        selectedModelIds = Set(availableModels.map { $0.id })
                    }
                    .font(.caption)
                    
                    Button("customProviders.deselectAll".localized()) {
                        selectedModelIds.removeAll()
                    }
                    .font(.caption)
                }
            }
        }
    }
    
    private func modelSelectionRow(model: AvailableModel) -> some View {
        Button {
            if selectedModelIds.contains(model.id) {
                selectedModelIds.remove(model.id)
            } else {
                selectedModelIds.insert(model.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedModelIds.contains(model.id) ? "checkmark.square" : "square")
                    .foregroundStyle(selectedModelIds.contains(model.id) ? Color.accentColor : .secondary)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if model.id != model.name {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var manualModelEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("customProviders.enterManually".localized())
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            Button {
                models.append(ModelMapping(name: "", alias: ""))
            } label: {
                Label("customProviders.addMapping".localized(), systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.sectionHeader)
            
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
            .disabled(isTestingConnection)
            
            Spacer()
            
            if isTestingConnection {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("customProviders.testing".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Button(isEditing ? "customProviders.saveChanges".localized() : "customProviders.addProvider".localized()) {
                saveProvider()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(isTestingConnection)
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
        
        // Set selected models from existing provider
        selectedModelIds = Set(provider.models.map { $0.name })
    }
    
    private func fetchModelsFromAPI() {
        guard let firstKey = apiKeys.first, !firstKey.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            modelFetchError = "Enter an API key first"
            return
        }
        
        let effectiveBaseURL = baseURL.isEmpty 
            ? (providerType.defaultBaseURL ?? "")
            : baseURL
        
        guard let url = URL(string: effectiveBaseURL) else {
            modelFetchError = "Invalid base URL"
            return
        }
        
        let modelsURL = url.appendingPathComponent("v1/models")
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        
        // Set authorization header based on provider type
        switch providerType {
        case .openaiCompatibility, .codexCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        case .claudeCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiCompatibility:
            var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "key", value: firstKey.apiKey)]
            if let newURL = components?.url {
                request.url = newURL
            }
        case .glmCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // Add custom headers
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        
        isLoadingModels = true
        modelFetchError = nil
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        isLoadingModels = false
                        modelFetchError = "Invalid response"
                    }
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        isLoadingModels = false
                        modelFetchError = "Failed to fetch models: HTTP \(httpResponse.statusCode)"
                    }
                    return
                }
                
                let modelsResponse = try JSONDecoder().decode(ModelsListResponse.self, from: data)
                let fetchedModels = modelsResponse.allModels.map { $0.toAvailableModel() }
                
                await MainActor.run {
                    isLoadingModels = false
                    availableModels = fetchedModels.sorted { $0.name < $1.name }
                }
            } catch {
                await MainActor.run {
                    isLoadingModels = false
                    modelFetchError = "Failed to fetch models: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveProvider() {
        // Clear previous errors
        testError = nil
        
        // Convert selected model IDs to ModelMapping
        let selectedModelMappings = selectedModelIds.compactMap { modelId -> ModelMapping? in
            guard let model = availableModels.first(where: { $0.id == modelId }) else { return nil }
            return ModelMapping(name: model.id, alias: model.id)
        }
        
        // Merge with manually added models
        let allModels = models.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } + selectedModelMappings
        
        // Build provider
        let newProvider = CustomProvider(
            id: provider?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            type: providerType,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            prefix: prefix.trimmingCharacters(in: .whitespaces).isEmpty ? nil : prefix.trimmingCharacters(in: .whitespaces),
            apiKeys: apiKeys.filter { !$0.apiKey.trimmingCharacters(in: .whitespaces).isEmpty },
            models: allModels,
            headers: headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty },
            isEnabled: isEnabled,
            createdAt: provider?.createdAt ?? Date(),
            updatedAt: Date()
        )
        
        // Validate basic fields
        validationErrors = CustomProviderService.shared.validateProvider(newProvider)
        
        if !validationErrors.isEmpty {
            showValidationAlert = true
            return
        }
        
        // Test connection before saving
        isTestingConnection = true
        
        Task {
            do {
                let success = try await testConnection(provider: newProvider)
                await MainActor.run {
                    isTestingConnection = false
                    if success {
                        onSave(newProvider)
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    testError = error.localizedDescription
                    showValidationAlert = true
                }
            }
        }
    }
    
    private func testConnection(provider: CustomProvider) async throws -> Bool {
        guard let firstKey = provider.apiKeys.first else {
            throw CustomProviderTestError.noAPIKey
        }
        
        let effectiveBaseURL = provider.baseURL.isEmpty 
            ? (provider.type.defaultBaseURL ?? "")
            : provider.baseURL
        
        guard let url = URL(string: effectiveBaseURL) else {
            throw CustomProviderTestError.invalidURL
        }
        
        let modelsURL = url.appendingPathComponent("v1/models")
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        
        // Set authorization header based on provider type
        switch provider.type {
        case .openaiCompatibility, .codexCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        case .claudeCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiCompatibility:
            // Gemini uses query parameter for API key
            var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "key", value: firstKey.apiKey)]
            if let newURL = components?.url {
                request.url = newURL
            }
        case .glmCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // Add custom headers if any
        for header in provider.headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomProviderTestError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200..<300:
            return true
        case 401, 403:
            throw CustomProviderTestError.unauthorized
        case 404:
            throw CustomProviderTestError.endpointNotFound
        default:
            if let errorMessage = String(data: data, encoding: .utf8) {
                throw CustomProviderTestError.serverError(httpResponse.statusCode, errorMessage)
            }
            throw CustomProviderTestError.serverError(httpResponse.statusCode, "Unknown error")
        }
    }
}

enum CustomProviderTestError: LocalizedError {
    case noAPIKey
    case invalidURL
    case invalidResponse
    case unauthorized
    case endpointNotFound
    case serverError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key provided"
        case .invalidURL:
            return "Invalid base URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "API key is invalid or unauthorized"
        case .endpointNotFound:
            return "Models endpoint not found at this URL"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

// MARK: - Models Response Parsing

private struct ModelsListResponse: Codable {
    let data: [ModelData]?
    let models: [ModelData]?
    
    var allModels: [ModelData] {
        data ?? models ?? []
    }
}

private struct ModelData: Codable {
    let id: String
    let name: String?
    let ownedBy: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case ownedBy = "owned_by"
    }
    
    func toAvailableModel() -> AvailableModel {
        AvailableModel(id: id, name: name ?? id, provider: ownedBy ?? "unknown", isDefault: false)
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
