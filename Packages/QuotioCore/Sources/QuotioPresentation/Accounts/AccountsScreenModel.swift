import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class AccountsScreenModel {
    public private(set) var accounts: [Account] = []
    public private(set) var nativeSourcePermissions: [NativeSourcePermission] = []
    public private(set) var authorizedNativeSources: [NativeSourcePermission] = []
    public private(set) var isScanningAll = false
    public private(set) var authorizingNativeSourceID: String?
    public private(set) var storageProblem: AccountStorageProblem?
    public private(set) var authorizingStorage = false
    public private(set) var nativeAuthorizationFailure: NativeSourceAuthorizationFailure?
    public private(set) var lastScannedAt: [QuotaProvider: Date] = [:]
    public private(set) var failedDiscoveryProviders: Set<QuotaProvider> = []
    public private(set) var discoveringProvider: QuotaProvider?
    public private(set) var failure: AccountServiceFailure?

    @ObservationIgnored private let accountService: any AccountManaging

    public init(
        accountService: any AccountManaging
    ) {
        self.accountService = accountService
    }

    public func reloadAccounts() async {
        accounts = await accountService.accounts()
        await reloadDiscovery()
        storageProblem = await accountService.accountStorageProblem()
    }

    public func registerDetectedNativeAccounts() async {
        await accountService.registerDetectedNativeAccounts()
        await reloadDiscovery()
        storageProblem = await accountService.accountStorageProblem()
    }

    public func scanAllNativeAccounts() async {
        guard !isScanningAll else { return }
        isScanningAll = true
        defer { isScanningAll = false }
        await accountService.rescanAllNativeAccounts()
        await reloadDiscovery()
        await reloadAccounts()
    }

    public func rescanNativeAccounts(for provider: QuotaProvider) async {
        guard discoveringProvider == nil else { return }
        discoveringProvider = provider
        defer { discoveringProvider = nil }
        await accountService.rescanNativeAccounts(for: provider)
        await reloadDiscovery()
        storageProblem = await accountService.accountStorageProblem()
        await reloadAccounts()
    }

    public func authorizeNativeSource(_ source: NativeSourcePermission) async throws {
        nativeAuthorizationFailure = nil
        authorizingNativeSourceID = source.id
        defer { authorizingNativeSourceID = nil }
        do {
            try await accountService.authorizeNativeSource(source)
        } catch {
            nativeAuthorizationFailure = error as? NativeSourceAuthorizationFailure ?? .unknown
            storageProblem = await accountService.accountStorageProblem()
            throw error
        }
        await reloadDiscovery()
        storageProblem = await accountService.accountStorageProblem()
        await reloadAccounts()
    }

    public func authorizeAccountStorage() async throws {
        guard !authorizingStorage else { return }
        authorizingStorage = true
        defer { authorizingStorage = false }
        do {
            try await accountService.authorizeAccountStorage()
            storageProblem = await accountService.accountStorageProblem()
            await reloadDiscovery()
            await reloadAccounts()
        } catch {
            nativeAuthorizationFailure = error as? NativeSourceAuthorizationFailure ?? .unknown
            throw error
        }
    }

    private func reloadDiscovery() async {
        let state = await accountService.nativeDiscoverySnapshot()
        nativeSourcePermissions = state.permissions
        authorizedNativeSources = state.knownSources
        lastScannedAt = state.scannedAt
        failedDiscoveryProviders = state.failedProviders
    }

    public func replaceAccounts(_ accounts: [Account]) {
        self.accounts = accounts
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        await accountService.setDisabled(disabled, accountID: accountID)
        await reloadAccounts()
    }

    public func delete(accountID: String) async throws {
        do {
            try await accountService.delete(accountID: accountID)
            await reloadAccounts()
            failure = nil
        } catch let error as AccountServiceFailure {
            failure = error
            throw error
        }
    }

    public func renameAccount(id: String, userLabel: String?) async throws {
        try await accountService.renameResolvedAccount(id: id, userLabel: userLabel)
        await reloadAccounts()
    }

    public func setSourceEnabled(_ enabled: Bool, sourceID: String) async throws {
        try await accountService.setSourceEnabled(enabled, sourceID: sourceID)
        await reloadAccounts()
    }

    public func unlinkSource(sourceID: String) async throws {
        try await accountService.unlinkSource(sourceID: sourceID)
        await reloadAccounts()
        await reloadDiscovery()
    }

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String? = nil,
        fields: [String: String] = [:]
    ) async throws {
        do {
            try await accountService.saveAPIKey(
                providerID: providerID,
                label: label,
                apiKey: apiKey,
                existingAccountID: existingAccountID,
                fields: fields
            )
            await reloadAccounts()
            failure = nil
        } catch let error as AccountServiceFailure {
            failure = error
            throw error
        }
    }

}
