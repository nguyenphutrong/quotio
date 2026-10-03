import Observation
import QuotioApplication
import SwiftUI

@MainActor
@Observable
public final class CredentialMigrationScreenModel {
    public private(set) var result = CredentialMigrationResult()
    public private(set) var isRunning = false
    @ObservationIgnored private let run: @Sendable () async -> CredentialMigrationResult

    public init(run: @escaping @Sendable () async -> CredentialMigrationResult) {
        self.run = run
    }

    public func migrate() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        result = await run()
    }
}

struct CredentialMigrationSection: View {
    @Environment(CredentialMigrationScreenModel.self) private var model

    var body: some View {
        Section {
            Text("settings.credentialMigration.help".localized())
            if model.result.metadataUnreadable {
                Text("settings.credentialMigration.metadataError".localized())
                    .foregroundStyle(.orange)
            }
            if model.result.pendingCount > 0 {
                Text(String(format: "settings.credentialMigration.pending".localized(), model.result.pendingCount))
                    .foregroundStyle(.orange)
            }
            if model.result.migratedCount > 0 {
                Text(String(format: "settings.credentialMigration.completed".localized(), model.result.migratedCount))
            }
            Button("settings.credentialMigration.retry".localized()) {
                Task { await model.migrate() }
            }
            .disabled(model.isRunning)
        } header: {
            Label("settings.credentialMigration.title".localized(), systemImage: "key")
        }
    }
}
