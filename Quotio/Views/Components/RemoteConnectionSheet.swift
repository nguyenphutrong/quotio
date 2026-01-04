//
//  RemoteConnectionSheet.swift
//  Quotio - Remote CLIProxyAPI connection configuration
//

import SwiftUI

struct RemoteConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel
    
    let existingConfig: RemoteConnectionConfig?
    let onSave: (RemoteConnectionConfig, String) -> Void
    
    @State private var displayName: String = ""
    @State private var endpointURL: String = ""
    @State private var managementKey: String = ""
    @State private var verifySSL: Bool = true
    @State private var timeoutSeconds: Int = 30
    @State private var isTestingConnection = false
    @State private var testResult: RemoteTestResult?
    
    private var isEditing: Bool { existingConfig != nil }
    
    private var urlValidation: RemoteURLValidationResult {
        RemoteURLValidator.validate(endpointURL)
    }
    
    private var canSave: Bool {
        urlValidation == .valid && !managementKey.isEmpty && !displayName.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionSection
                    authenticationSection
                    advancedSection
                    
                    if let result = testResult {
                        testResultSection(result)
                    }
                }
                .padding(20)
            }
            
            Divider()
            footerView
        }
        .frame(width: 500, height: 550)
        .onAppear {
            loadExistingConfig()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "remote.edit".localized() : "remote.configure".localized())
                    .font(.headline)
                
                Text("remote.description".localized())
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
    
    // MARK: - Connection Section
    
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("remote.connection".localized())
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("remote.displayName".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("remote.displayName.placeholder".localized(), text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("remote.endpointURL".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("https://proxy.example.com:8317", text: $endpointURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                if let errorMessage = urlValidation.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Authentication Section
    
    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("remote.authentication".localized())
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("remote.managementKey".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                SecureField("remote.managementKey.placeholder".localized(), text: $managementKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("remote.managementKey.hint".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Advanced Section
    
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("remote.advanced".localized())
                .font(.headline)
            
            Toggle("remote.verifySSL".localized(), isOn: $verifySSL)
            
            HStack {
                Text("remote.timeout".localized())
                Spacer()
                Picker("", selection: $timeoutSeconds) {
                    Text("15s").tag(15)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                    Text("120s").tag(120)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Test Result Section
    
    private func testResultSection(_ result: RemoteTestResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(result.success ? "remote.test.success".localized() : "remote.test.failed".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let message = result.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding()
        .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack(spacing: 12) {
            Button("remote.test".localized()) {
                Task {
                    await testConnection()
                }
            }
            .disabled(!canSave || isTestingConnection)
            
            Spacer()
            
            Button("action.cancel".localized()) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Button("action.save".localized()) {
                saveConfiguration()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(20)
    }
    
    // MARK: - Actions
    
    private func loadExistingConfig() {
        guard let config = existingConfig else { return }
        
        displayName = config.displayName
        endpointURL = config.endpointURL
        verifySSL = config.verifySSL
        timeoutSeconds = config.timeoutSeconds
        
        if let key = KeychainHelper.getManagementKey(for: config.id) {
            managementKey = key
        }
    }
    
    private func testConnection() async {
        isTestingConnection = true
        testResult = nil
        
        let config = RemoteConnectionConfig(
            endpointURL: RemoteURLValidator.sanitize(endpointURL),
            displayName: displayName,
            verifySSL: verifySSL,
            timeoutSeconds: timeoutSeconds
        )
        
        let client = ManagementAPIClient(config: config, managementKey: managementKey)
        let success = await client.checkProxyResponding()
        await client.invalidate()
        
        testResult = RemoteTestResult(
            success: success,
            message: success ? nil : "remote.test.cannotConnect".localized()
        )
        
        isTestingConnection = false
    }
    
    private func saveConfiguration() {
        let config = RemoteConnectionConfig(
            endpointURL: RemoteURLValidator.sanitize(endpointURL),
            displayName: displayName,
            verifySSL: verifySSL,
            timeoutSeconds: timeoutSeconds,
            id: existingConfig?.id ?? UUID().uuidString
        )
        
        onSave(config, managementKey)
        dismiss()
    }
}

struct RemoteTestResult {
    let success: Bool
    let message: String?
}
