//
//  APIKeysScreen.swift
//  Quotio
//

import SwiftUI
import AppKit

struct APIKeysScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    @State private var newAPIKey: String = ""
    @State private var editingKeyIndex: Int? = nil
    @State private var editedKeyValue: String = ""
    @State private var showingAddKey: Bool = false
    
    var body: some View {
        Group {
            if !viewModel.proxyManager.proxyStatus.running {
                proxyNotRunningView
            } else {
                apiKeysListView
            }
        }
        .navigationTitle("nav.apiKeys".localized())
        .toolbar {
            if viewModel.proxyManager.proxyStatus.running {
                ToolbarItemGroup {
                    Button {
                        newAPIKey = generateRandomKey()
                        showingAddKey = true
                    } label: {
                        Label("apiKeys.generate".localized(), systemImage: "wand.and.stars")
                    }
                    .help("apiKeys.generateHelp".localized())
                    
                    Button {
                        showingAddKey = true
                    } label: {
                        Label("apiKeys.add".localized(), systemImage: "plus")
                    }
                    .help("apiKeys.addHelp".localized())
                }
            }
        }
    }
    
    private var proxyNotRunningView: some View {
        ProxyRequiredView(
            description: "apiKeys.proxyRequired".localized()
        ) {
            await viewModel.startProxy()
        }
    }
    
    private var apiKeysListView: some View {
        List {
            Section {
                ForEach(Array(viewModel.apiKeys.enumerated()), id: \.offset) { index, key in
                    APIKeyRow(
                        key: key,
                        isEditing: editingKeyIndex == index,
                        editedValue: $editedKeyValue,
                        onEdit: {
                            editingKeyIndex = index
                            editedKeyValue = key
                        },
                        onSave: {
                            Task {
                                await viewModel.updateAPIKey(old: key, new: editedKeyValue)
                                editingKeyIndex = nil
                                editedKeyValue = ""
                            }
                        },
                        onCancel: {
                            editingKeyIndex = nil
                            editedKeyValue = ""
                        },
                        onCopy: {
                            copyToClipboard(key)
                        },
                        onDelete: {
                            Task {
                                await viewModel.deleteAPIKey(key)
                            }
                        }
                    )
                }
                
                if showingAddKey {
                    AddAPIKeyRow(
                        newKey: $newAPIKey,
                        onSave: addNewKey,
                        onCancel: {
                            showingAddKey = false
                            newAPIKey = ""
                        },
                        onGenerate: {
                            newAPIKey = generateRandomKey()
                        }
                    )
                }
            } header: {
                HStack {
                    Text("apiKeys.list".localized())
                    Spacer()
                    Text("\(viewModel.apiKeys.count)")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("apiKeys.description".localized())
            }
        }
        .overlay {
            if viewModel.apiKeys.isEmpty && !showingAddKey {
                ContentUnavailableView {
                    Label("apiKeys.empty".localized(), systemImage: "key.slash")
                } description: {
                    Text("apiKeys.emptyDescription".localized())
                } actions: {
                    Button {
                        newAPIKey = generateRandomKey()
                        showingAddKey = true
                    } label: {
                        Text("apiKeys.generateFirst".localized())
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
    
    private func addNewKey() {
        let trimmed = newAPIKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        Task {
            await viewModel.addAPIKey(trimmed)
            newAPIKey = ""
            showingAddKey = false
        }
    }
    
    private func generateRandomKey() -> String {
        let prefix = "sk-"
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomPart = String((0..<32).map { _ in characters.randomElement()! })
        return prefix + randomPart
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct APIKeyRow: View {
    let key: String
    let isEditing: Bool
    @Binding var editedValue: String
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            if isEditing {
                TextField("apiKeys.placeholder".localized(), text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(onSave)
                
                Button(action: onSave) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Text(maskedKey)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                
                Spacer()
                
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("action.copy".localized())
                
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("apiKeys.edit".localized())
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("action.delete".localized())
            }
        }
        .padding(.vertical, 4)
    }
    
    private var maskedKey: String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = String(key.prefix(6))
        let suffix = String(key.suffix(4))
        return "\(prefix)••••••••\(suffix)"
    }
}

struct AddAPIKeyRow: View {
    @Binding var newKey: String
    let onSave: () -> Void
    let onCancel: () -> Void
    let onGenerate: () -> Void
    
    var body: some View {
        HStack {
            TextField("apiKeys.placeholder".localized(), text: $newKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(onSave)
            
            Button(action: onGenerate) {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .help("apiKeys.generate".localized())
            
            Button(action: onSave) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
