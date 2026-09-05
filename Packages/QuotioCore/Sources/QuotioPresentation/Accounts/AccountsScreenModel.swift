import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class AccountsScreenModel {
    public private(set) var accounts: [Account] = []
    public private(set) var authFiles: [AuthFileDescriptor] = []
    public private(set) var failure: AccountServiceFailure?

    @ObservationIgnored private var accountAliases: [QuotaProvider: [String: String]] = [:]
    @ObservationIgnored private let accountService: any AccountManaging
    @ObservationIgnored private let authFileRepository: any AuthFileRepository

    public init(
        accountService: any AccountManaging,
        authFileRepository: any AuthFileRepository
    ) {
        self.accountService = accountService
        self.authFileRepository = authFileRepository
    }

    public func reloadAccounts() async {
        accounts = canonicalized(await accountService.accounts())
    }

    public func reloadAccounts(
        merging quotas: [QuotaProvider: [String: ProviderQuota]],
        aliases: [QuotaProvider: [String: String]] = [:]
    ) async {
        accountAliases = aliases
        accounts = AccountSelectionPolicy.mergingQuotaAccounts(
            canonicalized(await accountService.accounts()),
            quotas: quotas
        )
    }

    private func canonicalized(_ candidates: [Account]) -> [Account] {
        guard !accountAliases.isEmpty else { return candidates }
        let canonical = candidates.map { account in
            guard let provider = QuotaProvider(rawValue: account.providerID.rawValue),
                  let key = accountAliases[provider]?[account.accountKey] else { return account }
            return Account(
                identity: AccountIdentity(id: account.id, providerID: account.providerID, accountKey: key),
                displayName: account.displayName,
                source: account.source,
                credentialReference: account.credentialReference,
                capabilities: account.capabilities,
                status: account.status,
                credentialMetadata: account.credentialMetadata
            )
        }
        return AccountSelectionPolicy.preferred(
            canonical,
            disabledIDs: Set(canonical.filter(\.isDisabled).map(\.id))
        )
    }

    public func reloadAuthFiles() async {
        authFiles = await authFileRepository.scanAllAuthFiles()
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

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String? = nil
    ) async throws {
        do {
            try await accountService.saveAPIKey(
                providerID: providerID,
                label: label,
                apiKey: apiKey,
                existingAccountID: existingAccountID
            )
            await reloadAccounts()
            failure = nil
        } catch let error as AccountServiceFailure {
            failure = error
            throw error
        }
    }

    public func importAuthFile(from url: URL) async throws {
        let content = try await authFileRepository.readAuthFileForImport(from: url)
        try await authFileRepository.uploadAuthFile(name: url.lastPathComponent, content: content)
        await reloadAuthFiles()
    }

    public func readAuthFileForImport(from url: URL) async throws -> Data {
        try await authFileRepository.readAuthFileForImport(from: url)
    }

    public func writeDownloadedAuthFile(_ content: Data, to url: URL) async throws {
        try await authFileRepository.writeDownloadedAuthFile(content, to: url)
    }

    public func exportAuthFile(name: String, to url: URL) async throws {
        let content = try await authFileRepository.downloadAuthFile(name: name)
        try await authFileRepository.writeDownloadedAuthFile(content, to: url)
    }
}
