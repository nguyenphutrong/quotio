//
//  WarpConnectionSheet.swift
//  Quotio
//
//  Dedicated connection sheet for Warp AI Terminal.
//

import SwiftUI

struct WarpConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let token: WarpService.WarpToken?
    let onSave: (String, String) -> Void
    
    @State private var name: String = ""
    @State private var tokenString: String = ""
    
    private var isEditing: Bool {
        token != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("customProviders.providerName".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    TextField("warp.name.placeholder".localized(), text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("warp.token.label".localized())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        if let docsURL = URL(string: "https://docs.warp.dev/platform/cli#generating-api-keys") {
                            Link(destination: docsURL) {
                                HStack(spacing: 4) {
                                    Text("warp.token.get".localized())
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.caption)
                            }
                        }
                    }
                    
                    SecureField("warp.token.placeholder".localized(), text: $tokenString)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("warp.token.description".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
            }
            .padding(24)
            
            Divider()
            
            footerView
        }
        .frame(width: 450, height: 350)
        .onAppear {
            if let token = token {
                name = token.name
                tokenString = token.token
            }
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 16) {
            Image("warp")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "warp.connection.edit".localized() : "warp.connection.title".localized())
                    .font(.headline)
                
                Text("warp.connection.subtitle".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(20)
    }
    
    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) {
                dismiss()
            }
            
            Spacer()
            
            Button(isEditing ? "action.save".localized() : "action.connect".localized()) {
                onSave(name, tokenString)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty || tokenString.isEmpty)
        }
        .padding(20)
    }
}
