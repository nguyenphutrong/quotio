import QuotioDomain
import SwiftUI

struct AboutSettingsPage: View {
    @Environment(ApplicationUpdateScreenModel.self) private var update
    @Environment(SettingsScreenModel.self) private var settings
    @Environment(PasteboardScreenModel.self) private var pasteboard

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—") + ")"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image("AppIconImage").resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading) {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                             ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quotio")
                            .font(.title2.weight(.semibold))
                        Button(version) { pasteboard.copy(version) }.buttonStyle(.plain)
                            .help("settings.copyVersion".localized())
                    }
                }
                if update.snapshot.policy == .manualDownload {
                    Text("settings.manualAppUpdates".localized())
                        .foregroundStyle(.secondary)
                    Link("settings.downloadAppUpdates".localized(),
                         destination: URL(string: "https://github.com/nguyenphutrong/quotio/releases")!)
                } else {
                    Button("action.checkUpdates".localized()) { update.checkForUpdates() }
                        .disabled(!update.snapshot.canCheck || update.snapshot.isChecking)
                    Toggle("settings.autoCheckUpdates".localized(), isOn: Binding(
                        get: { settings.appShellPreferences.autoCheckUpdates }, set: { settings.setAutomaticUpdateChecks($0) }
                    ))
                    if let date = update.snapshot.lastCheckDate {
                        LabeledContent("settings.lastChecked".localized()) {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                }
            }
            Section("settings.links".localized()) {
                Link("GitHub · Quotio", destination: URL(string: "https://github.com/nguyenphutrong/quotio")!)
                Link("GitHub · CLIProxyAPI", destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!)
                Link("settings.sponsors".localized(), destination: URL(string: "https://www.quotio.dev/sponsors")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("settings.aboutUpdates".localized())
        .onAppear { update.initializeIfNeeded() }
    }
}
