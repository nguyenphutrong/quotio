//
//  IDEScanSheet.swift
//  Quotio - IDE Scan Consent Dialog
//
//  Shows privacy notice and allows user to select what to scan
//  User must explicitly trigger scan - addresses issue #29
//

import SwiftUI

struct IDEScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel
    
    @State private var scanOptions = IDEScanOptions.defaultOptions
    @State private var isScanning = false
    @State private var scanComplete = false
    @State private var errorMessage: String?
    
    let onScanComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    privacyNoticeSection
                    scanOptionsSection
                    
                    if scanComplete {
                        scanResultSection
                    }
                    
                    if let error = errorMessage {
                        errorSection(error)
                    }
                }
                .padding(24)
            }
            
            Divider()
            
            // Footer buttons
            footerSection
        }
        .frame(width: 520, height: 520)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("ideScan.title".localized())
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("ideScan.subtitle".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(24)
    }
    
    // MARK: - Privacy Notice
    
    private var privacyNoticeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                
                Text("ideScan.privacyNotice".localized())
                    .font(.headline)
            }
            
            Text("ideScan.privacyDescription".localized())
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(12)
    }
    
    // MARK: - Scan Options
    
    private var scanOptionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ideScan.selectSources".localized())
                .font(.headline)
            
            VStack(spacing: 12) {
                // Cursor IDE
                scanOptionRow(
                    icon: "cursor-menubar",
                    iconFallback: "laptopcomputer",
                    title: "Cursor IDE",
                    detail: "ideScan.cursor.detail".localized(),
                    isOn: $scanOptions.scanCursor
                )
                
                // Trae IDE
                scanOptionRow(
                    icon: "trae-menubar",
                    iconFallback: "laptopcomputer",
                    title: "Trae IDE",
                    detail: "ideScan.trae.detail".localized(),
                    isOn: $scanOptions.scanTrae
                )
                
                // CLI Tools
                scanOptionRow(
                    icon: nil,
                    iconFallback: "terminal.fill",
                    title: "ideScan.cliTools".localized(),
                    detail: "ideScan.cliTools.detail".localized(),
                    isOn: $scanOptions.scanCLITools
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func scanOptionRow(
        icon: String?,
        iconFallback: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            if let iconName = icon {
                Image(iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: iconFallback)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Scan Result
    
    private var scanResultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                
                Text("ideScan.complete".localized())
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            
            if let result = IDEScanSettingsManager.shared.lastScanResult {
                VStack(alignment: .leading, spacing: 8) {
                    if result.cursorFound {
                        resultRow(icon: "checkmark.circle.fill", color: .green, text: "Cursor: \(result.cursorEmail ?? "Found")")
                    } else if scanOptions.scanCursor {
                        resultRow(icon: "xmark.circle.fill", color: .secondary, text: "Cursor: " + "ideScan.notFound".localized())
                    }
                    
                    if result.traeFound {
                        resultRow(icon: "checkmark.circle.fill", color: .green, text: "Trae: \(result.traeEmail ?? "Found")")
                    } else if scanOptions.scanTrae {
                        resultRow(icon: "xmark.circle.fill", color: .secondary, text: "Trae: " + "ideScan.notFound".localized())
                    }
                    
                    if !result.cliToolsFound.isEmpty {
                        resultRow(icon: "checkmark.circle.fill", color: .green, text: "CLI: \(result.cliToolsFound.joined(separator: ", "))")
                    } else if scanOptions.scanCLITools {
                        resultRow(icon: "xmark.circle.fill", color: .secondary, text: "CLI: " + "ideScan.notFound".localized())
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .cornerRadius(12)
    }
    
    private func resultRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            
            Text(text)
                .font(.callout)
        }
    }
    
    // MARK: - Error Section
    
    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                
                Text("ideScan.error".localized())
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            Button("action.cancel".localized()) {
                dismiss()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            if scanComplete {
                Button("action.done".localized()) {
                    onScanComplete()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    performScan()
                } label: {
                    if isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("ideScan.scanning".localized())
                        }
                    } else {
                        Label("ideScan.scanNow".localized(), systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scanOptions.hasAnyScanEnabled || isScanning)
            }
        }
        .padding(20)
    }
    
    // MARK: - Actions
    
    private func performScan() {
        isScanning = true
        errorMessage = nil
        scanComplete = false
        
        Task {
            do {
                await viewModel.scanIDEsWithConsent(options: scanOptions)
                
                await MainActor.run {
                    isScanning = false
                    scanComplete = true
                }
            } catch {
                await MainActor.run {
                    isScanning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    IDEScanSheet(onScanComplete: {})
        .environment(QuotaViewModel())
}
