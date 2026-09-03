import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class DashboardScreenModel {
    public let quota: QuotaScreenModel
    public let accounts: AccountsScreenModel

    public init(quota: QuotaScreenModel, accounts: AccountsScreenModel) {
        self.quota = quota
        self.accounts = accounts
    }

    public var trackedAccountCount: Int { accounts.accounts.count }

    public var connectedProviderCount: Int {
        Set(accounts.accounts.map { QuotaProvider(rawValue: $0.providerID.rawValue) }.compactMap { $0 }).count
    }

    public var lowestQuotaPercentage: Double {
        quota.providerQuotas.values
            .flatMap(\.values)
            .map(QuotaPolicy.lowestAvailablePercentage)
            .filter { $0 >= 0 }
            .min() ?? 100
    }

    public var lastRefreshTime: Date? { quota.lastRefreshTime }

    public func refresh(mode: QuotaOperatingMode) async {
        await quota.refreshAll(mode: mode, force: true)
    }
}
