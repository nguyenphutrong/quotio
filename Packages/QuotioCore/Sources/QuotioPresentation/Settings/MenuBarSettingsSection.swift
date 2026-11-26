import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI

struct MenuBarSettingsSection: View {
    @Environment(QuotaFeatureController.self) private var viewModel
    @Environment(MenuBarSettingsManager.self) private var settings
    @Environment(SettingsScreenModel.self) private var settingsModel
    @State private var showTruncationAlert = false
    @State private var pendingMaxItems: Int?

    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarIcon },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !settingsModel.appShellPreferences.showInDock {
                    // Re-enable dock if user tries to disable menu bar icon while dock is already disabled
                    settingsModel.setShowInDock(true)
                }
                settings.showMenuBarIcon = newValue
            }
        )
    }

    private var showQuotaBinding: Binding<Bool> {
        Binding(
            get: { settings.showQuotaInMenuBar },
            set: { settings.showQuotaInMenuBar = $0 }
        )
    }

    private var colorModeBinding: Binding<MenuBarColorMode> {
        Binding(
            get: { settings.colorMode },
            set: { settings.colorMode = $0 }
        )
    }

    private var colorBasisBinding: Binding<MenuBarColorBasis> {
        Binding(
            get: { settings.colorBasis },
            set: { settings.colorBasis = $0 }
        )
    }

    private var stackPairedQuotaMetricsBinding: Binding<Bool> {
        Binding(
            get: { settings.stackPairedQuotaMetrics },
            set: { settings.stackPairedQuotaMetrics = $0 }
        )
    }

    private var maxItemsBinding: Binding<Int> {
        Binding(
            get: { settings.menuBarMaxItems },
            set: { newValue in
                let clamped = min(max(newValue, MenuBarSettingsManager.minMenuBarItems), MenuBarSettingsManager.maxMenuBarItems)

                // Check if reducing max items would truncate current selection
                if clamped < settings.menuBarMaxItems && settings.currentItems.count > clamped {
                    pendingMaxItems = clamped
                    showTruncationAlert = true
                } else {
                    settings.menuBarMaxItems = clamped
                    viewModel.synchronizeMenuBarSelection()
                }
            }
        )
    }

    var body: some View {
        Section {
            Toggle("settings.menubar.showIcon".localized(), isOn: showMenuBarIconBinding)

            if settings.showMenuBarIcon {
                Toggle("settings.menubar.showQuota".localized(), isOn: showQuotaBinding)

                if settings.showQuotaInMenuBar {
                    Toggle(
                        "settings.menubar.stackPairedQuotaMetrics".localized(),
                        isOn: stackPairedQuotaMetricsBinding
                    )

                    HStack {
                        Text("settings.menubar.maxItems".localized())
                        Spacer()
                        Text("\(settings.menuBarMaxItems)")
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Stepper(
                            "",
                            value: maxItemsBinding,
                            in: MenuBarSettingsManager.minMenuBarItems...MenuBarSettingsManager.maxMenuBarItems,
                            step: 1
                        )
                        .labelsHidden()
                    }

                    Picker("settings.menubar.colorMode".localized(), selection: colorModeBinding) {
                        Text("settings.menubar.colored".localized()).tag(MenuBarColorMode.colored)
                        Text("settings.menubar.monochrome".localized()).tag(MenuBarColorMode.monochrome)
                    }
                    .pickerStyle(.segmented)

                    if settings.colorMode == .colored {
                        Picker("settings.menubar.colorBasis".localized(), selection: colorBasisBinding) {
                            ForEach(MenuBarColorBasis.allCases) { basis in
                                Text(basis.localizationKey.localized()).tag(basis)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        } header: {
            Label("settings.menubar".localized(), systemImage: "menubar.rectangle")
        } footer: {
            Text(String(
                format: "settings.menubar.help".localized(),
                settings.menuBarMaxItems
            ))
            .font(.caption)
        }
        .alert("menubar.truncation.title".localized(), isPresented: $showTruncationAlert) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMaxItems = nil
            }
            Button("action.ok".localized(), role: .destructive) {
                if let newMax = pendingMaxItems {
                    settings.menuBarMaxItems = newMax
                    viewModel.synchronizeMenuBarSelection()
                    pendingMaxItems = nil
                }
            }
        } message: {
            if let newMax = pendingMaxItems {
                Text(String(
                    format: "menubar.truncation.message".localized(),
                    settings.currentItems.count,
                    newMax
                ))
            }
        }
    }
}
