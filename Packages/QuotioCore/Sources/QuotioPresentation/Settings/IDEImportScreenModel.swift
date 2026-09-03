import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class IDEImportScreenModel {
    @ObservationIgnored private let quotaController: QuotaFeatureController
    @ObservationIgnored private let settings: IDEScanSettingsManager
    @ObservationIgnored private let cliToolProbe: any CLIToolInstallationProbing

    public init(
        quotaController: QuotaFeatureController,
        settings: IDEScanSettingsManager,
        cliToolProbe: any CLIToolInstallationProbing
    ) {
        self.quotaController = quotaController
        self.settings = settings
        self.cliToolProbe = cliToolProbe
    }

    func scan(options: IDEScanOptions) async {
        settings.setScanningState(true)
        defer { settings.setScanningState(false) }

        var cursorQuotas: [String: ProviderQuota] = [:]
        var traeQuotas: [String: ProviderQuota] = [:]
        if options.scanCursor {
            cursorQuotas = await quotaController.importIDEProvider(.cursor)
        }
        if options.scanTrae {
            traeQuotas = await quotaController.importIDEProvider(.trae)
        }

        var commandLineTools: [String] = []
        if options.scanCLITools {
            for name in ["claude", "codex", "gh"] where await cliToolProbe.isInstalled(binaryName: name) {
                commandLineTools.append(name)
            }
        }

        settings.updateScanResult(IDEScanResult(
            cursorFound: !cursorQuotas.isEmpty,
            cursorEmail: cursorQuotas.keys.sorted().first,
            traeFound: !traeQuotas.isEmpty,
            traeEmail: traeQuotas.keys.sorted().first,
            cliToolsFound: commandLineTools,
            timestamp: Date()
        ))
    }
}
