import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class ProvidersScreenModel {
    public let accounts: AccountsScreenModel
    public let oauth: OAuthScreenModel
    public let quota: QuotaScreenModel
    public private(set) var customProviders: [CustomProvider] = []
    public private(set) var errorMessage: String?

    @ObservationIgnored private let customProviderService: CustomProviderService

    public init(
        accounts: AccountsScreenModel,
        oauth: OAuthScreenModel,
        quota: QuotaScreenModel,
        customProviderService: CustomProviderService
    ) {
        self.accounts = accounts
        self.oauth = oauth
        self.quota = quota
        self.customProviderService = customProviderService
    }

    public func reloadCustomProviders() {
        do {
            customProviders = try customProviderService.providers()
            errorMessage = nil
        } catch {
            errorMessage = customProviderErrorMessage(error)
        }
    }

    public func validationIssues(for provider: CustomProvider) -> [CustomProviderValidationIssue] {
        do {
            return try customProviderService.validationIssues(for: provider)
        } catch {
            errorMessage = customProviderErrorMessage(error)
            return provider.validationIssues()
        }
    }

    public func save(_ provider: CustomProvider) throws {
        do {
            try customProviderService.save(provider)
            customProviders = try customProviderService.providers()
            errorMessage = nil
        } catch {
            errorMessage = customProviderErrorMessage(error)
            throw error
        }
    }

    public func synchronizeCustomProviders(at configurationPath: String) throws {
        do {
            try customProviderService.synchronizeConfiguration(at: configurationPath)
            errorMessage = nil
        } catch {
            errorMessage = customProviderErrorMessage(error)
            throw error
        }
    }

    public func deleteCustomProvider(id: UUID) throws {
        do {
            try customProviderService.delete(id: id)
            customProviders = try customProviderService.providers()
            errorMessage = nil
        } catch {
            errorMessage = customProviderErrorMessage(error)
            throw error
        }
    }

    public func discoverModels(for provider: CustomProvider) async throws -> [DiscoveredModel] {
        do {
            let models = try await customProviderService.discoverModels(for: provider)
            errorMessage = nil
            return models
        } catch {
            errorMessage = customProviderErrorMessage(error)
            throw error
        }
    }

    public func testConnection(to provider: CustomProvider) async throws {
        do {
            try await customProviderService.testConnection(to: provider)
            errorMessage = nil
        } catch {
            errorMessage = customProviderErrorMessage(error)
            throw error
        }
    }
}
