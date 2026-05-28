//
//  FallbackSheets.swift
//  Quotio
//

import AppKit
import SwiftUI

enum VirtualModelNameSheetMode {
    case create
    case edit

    var titleKey: String {
        switch self {
        case .create:
            return "virtualModels.createTitle"
        case .edit:
            return "virtualModels.renameTitle"
        }
    }

    var actionKey: String {
        switch self {
        case .create:
            return "action.create"
        case .edit:
            return "action.save"
        }
    }
}

struct VirtualModelNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: VirtualModelNameSheetMode
    let existingNames: Set<String>
    let originalName: String?
    var onSave: (String) -> Void

    @State private var name: String = ""
    @State private var didSubmit = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if trimmedName.isEmpty {
            return "virtualModels.validation.nameRequired".localized()
        }
        if trimmedName.contains("/") {
            return "virtualModels.nameNoSlash".localized()
        }

        let lowercasedNames = Set(existingNames.map { $0.lowercased() })
        let lowercasedOriginal = originalName?.lowercased()
        if lowercasedNames.contains(trimmedName.lowercased()),
           trimmedName.lowercased() != lowercasedOriginal {
            return "virtualModels.nameDuplicate".localized()
        }

        return nil
    }

    private var canSave: Bool {
        validationMessage == nil && trimmedName != (originalName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.titleKey.localized())
                        .font(.title3.weight(.semibold))
                    Text("virtualModels.createDescription".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("action.close".localized())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("virtualModels.modelName".localized())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("virtualModels.modelNamePlaceholder".localized(), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(save)

                if didSubmit, let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("virtualModels.nameHelp".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("action.cancel".localized(), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode.actionKey.localized()) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            name = originalName ?? ""
        }
    }

    private func save() {
        didSubmit = true
        guard canSave else { return }
        onSave(trimmedName)
        dismiss()
    }
}

struct VirtualModelTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let modelName: String
    let availableTargets: [VirtualModelAvailableTarget]
    let existingTargets: [String]
    var onAdd: ([String]) -> Void

    @State private var searchText = ""
    @State private var selectedTargets: Set<String> = []
    @State private var manualTarget = ""
    @State private var didSubmit = false

    private var existingTargetSet: Set<String> {
        Set(existingTargets.map { $0.lowercased() })
    }

    private var trimmedManualTarget: String {
        manualTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualValidationMessage: String? {
        guard !trimmedManualTarget.isEmpty else { return nil }
        if trimmedManualTarget.contains("/") {
            return "virtualModels.manualTargetNoSlash".localized()
        }
        if trimmedManualTarget.lowercased() == modelName.lowercased() {
            return "virtualModels.manualTargetSelf".localized()
        }
        if existingTargetSet.contains(trimmedManualTarget.lowercased()) {
            return "virtualModels.targetAlreadyAdded".localized()
        }
        return nil
    }

    private var filteredTargets: [VirtualModelAvailableTarget] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return availableTargets }
        return availableTargets.filter { target in
            [
                target.provider,
                target.model,
                target.target
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    private var canAdd: Bool {
        let hasValidManualTarget = !trimmedManualTarget.isEmpty && manualValidationMessage == nil
        let hasInvalidManualTarget = !trimmedManualTarget.isEmpty && manualValidationMessage != nil
        return !hasInvalidManualTarget && (!selectedTargets.isEmpty || hasValidManualTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("virtualModels.addTargetTitle".localized())
                        .font(.title3.weight(.semibold))
                    Text(String(format: "virtualModels.addTargetDescription".localized(), modelName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("action.close".localized())
            }

            searchField

            targetsList

            manualTargetField

            Divider()

            HStack {
                Text(String(format: "virtualModels.selectedTargetsFormat".localized(), selectedTargets.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("action.cancel".localized(), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("virtualModels.addSelected".localized()) {
                    addTargets()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 640, height: 620)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("virtualModels.searchTargets".localized(), text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var targetsList: some View {
        VStack(spacing: 0) {
            if availableTargets.isEmpty {
                VirtualModelSheetMessage(
                    title: "virtualModels.noAvailableTargets".localized(),
                    message: "virtualModels.noAvailableTargetsDescription".localized()
                )
            } else if filteredTargets.isEmpty {
                VirtualModelSheetMessage(
                    title: "virtualModels.noTargetMatches".localized(),
                    message: "virtualModels.noTargetMatchesDescription".localized()
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTargets) { target in
                            VirtualModelAvailableTargetRow(
                                target: target,
                                isSelected: selectedTargets.contains(target.target),
                                isExisting: existingTargetSet.contains(target.target.lowercased()),
                                onToggle: { selected in
                                    if selected {
                                        selectedTargets.insert(target.target)
                                    } else {
                                        selectedTargets.remove(target.target)
                                    }
                                }
                            )

                            if target.id != (filteredTargets.last?.id ?? "") {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 300)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var manualTargetField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("virtualModels.manualTarget".localized())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("virtualModels.manualTargetPlaceholder".localized(), text: $manualTarget)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(addTargets)

            if (didSubmit || !trimmedManualTarget.isEmpty), let manualValidationMessage {
                Text(manualValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("virtualModels.manualTargetHelp".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addTargets() {
        didSubmit = true
        guard canAdd else { return }

        var targets = availableTargets
            .filter { selectedTargets.contains($0.target) }
            .map(\.target)

        if !trimmedManualTarget.isEmpty {
            targets.append(trimmedManualTarget)
        }

        onAdd(targets)
        dismiss()
    }
}

private struct VirtualModelAvailableTargetRow: View {
    let target: VirtualModelAvailableTarget
    let isSelected: Bool
    let isExisting: Bool
    var onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: onToggle
            ))
            .labelsHidden()
            .disabled(isExisting)

            if let provider = AIProvider.fromProviderID(target.provider) {
                ProviderIcon(provider: provider, size: 22)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(target.target)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(target.provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isExisting {
                Text("virtualModels.alreadyAdded".localized())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(isExisting ? 0.55 : 1)
    }
}

private struct VirtualModelSheetMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
        .padding()
    }
}
