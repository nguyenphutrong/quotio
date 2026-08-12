//
//  ModelCatalog.swift
//  Quotio
//
//  Pure helpers for parsing the proxy's OpenAI-compatible /v1/models
//  response and grouping the resulting models by provider for display.
//

import Foundation

/// Models exposed by the proxy for a single provider.
nonisolated struct ProviderModelGroup: Identifiable, Equatable, Sendable {
    let provider: String
    let models: [AvailableModel]

    var id: String { provider }
}

nonisolated enum ModelCatalog {

    /// Decodes an OpenAI-compatible `/v1/models` response body into models.
    ///
    /// Each item's `owned_by` field becomes the model's provider,
    /// defaulting to `"openai"` when absent (mirrors historical behavior).
    static func parse(_ data: Data) throws -> [AvailableModel] {
        struct ModelsResponse: Decodable {
            struct ModelItem: Decodable {
                let id: String
                let owned_by: String?
            }
            let data: [ModelItem]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { item in
            AvailableModel(
                id: item.id,
                name: item.id,
                provider: item.owned_by ?? "openai",
                isDefault: false
            )
        }
    }

    /// Groups models by provider for display.
    ///
    /// Providers are sorted alphabetically (case-insensitive) and models
    /// within each provider are sorted by id. Duplicate model ids within
    /// the same provider are collapsed.
    static func groupByProvider(_ models: [AvailableModel]) -> [ProviderModelGroup] {
        let grouped = Dictionary(grouping: models) { $0.provider }

        return grouped
            .map { provider, models -> ProviderModelGroup in
                var seen = Set<String>()
                let uniqueSorted = models
                    .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                    .filter { seen.insert($0.id).inserted }
                return ProviderModelGroup(provider: provider, models: uniqueSorted)
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }
}
