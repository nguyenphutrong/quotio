import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI

struct RefreshCadenceSettingsSection: View {
    @Environment(QuotaFeatureController.self) private var viewModel
    private var cadenceBinding: Binding<Int> {
        Binding(
            get: { viewModel.monitoringSettings?.refreshInterval ?? 0 },
            set: { value in Task { await viewModel.setRefreshInterval(value) } }
        )
    }

    var body: some View {
        Section {
            Picker("settings.refresh.cadence".localized(), selection: cadenceBinding) {
                if let seconds = viewModel.monitoringSettings?.refreshInterval,
                   !RefreshCadence.allCases.contains(where: { Int($0.intervalSeconds ?? 0) == seconds }) {
                    Text(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds]))).tag(seconds)
                }
                ForEach(RefreshCadence.allCases) { cadence in
                    Text(cadence.localizationKey.localized()).tag(Int(cadence.intervalSeconds ?? 0))
                }
            }

            .disabled(!viewModel.canManageSettings || viewModel.monitoringSettings == nil || viewModel.isUpdatingSettings)
            if let error = viewModel.settingsError { Text(error).foregroundStyle(.red) }
            if viewModel.monitoringSettings?.refreshInterval == 0 {
                RefreshButton(title: "settings.refresh.now".localized(), isRefreshing: viewModel.quota.isLoadingQuotas) {
                    await viewModel.refreshAll(force: true)
                }
            }
        } header: {
            Label("settings.refresh".localized(), systemImage: "clock.arrow.2.circlepath")
        } footer: {
            Text("settings.refresh.help".localized())
                .font(.caption)
        }
    }
}
