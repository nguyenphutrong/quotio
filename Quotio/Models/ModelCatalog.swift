//
//  ModelCatalog.swift
//  Quotio
//
//  Pure helpers for parsing the proxy's OpenAI-compatible /v1/models
//  response, plus the display state that keeps a live catalog readout
//  distinguishable from a stale one.
//

import Foundation

/// One entry of the proxy's OpenAI-compatible `/v1/models` response.
///
/// This is deliberately a thin mirror of the wire format. It carries only what
/// `/v1/models` actually states: the model ID, and the `owned_by` metadata when
/// present. It says nothing about which provider account will serve a request
/// for the ID — the endpoint does not expose that.
nonisolated struct ModelCatalogEntry: Identifiable, Equatable, Sendable {
    /// The model ID exactly as listed by `/v1/models`.
    let id: String

    /// Raw `owned_by` value, or `nil` when the response omitted the field.
    ///
    /// This is static model-owner metadata. CLIProxyAPI deduplicates `/v1/models`
    /// by ID and tracks serving providers separately, so the value here may be
    /// replaced when another provider registers the same ID. Do not treat it as
    /// routing provenance.
    let owner: String?

    /// Owner metadata fit for display, or `nil` when the endpoint reported
    /// nothing usable (field absent, empty, or whitespace only).
    var displayOwner: String? {
        guard let trimmed = owner?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// How the catalog currently on screen relates to the proxy's live state.
nonisolated enum ModelCatalogFreshness: Equatable, Sendable {
    /// Nothing has been fetched successfully yet.
    case never

    /// The entries are exactly what `/v1/models` returned at `fetchedAt`.
    case live(fetchedAt: Date)

    /// A previous successful response is still on screen because a later
    /// fetch failed; it may no longer match the proxy.
    case stale(fetchedAt: Date)
}

/// Display state for the read-only model catalog.
///
/// Unlike `AgentSetupViewModel.availableModels`, this never substitutes
/// `AvailableModel.allModels` (or any other built-in list) for a missing or
/// failed response: a successful empty response stays empty, and a failed
/// refresh is reported as such instead of being papered over. That distinction
/// is what lets the UI claim "live" only when it really is.
nonisolated struct ModelCatalogState: Equatable, Sendable {
    /// Entries currently on screen, deduplicated by ID and sorted.
    private(set) var entries: [ModelCatalogEntry] = []

    private(set) var freshness: ModelCatalogFreshness = .never

    /// A fetch is in flight.
    private(set) var isLoading = false

    /// The most recent fetch attempt failed.
    private(set) var lastFetchFailed = false

    /// At least one fetch attempt has completed (successfully or not).
    ///
    /// Distinguishes "not fetched yet" from "fetched, and the proxy listed
    /// nothing" so the empty state is reachable.
    private(set) var hasCompletedFetch = false

    /// The proxy answered successfully and listed no models at all.
    var isEmptyLiveResult: Bool {
        hasCompletedFetch && !lastFetchFailed && entries.isEmpty
    }

    mutating func beginLoading() {
        isLoading = true
    }

    /// Records a successful `/v1/models` response verbatim.
    mutating func apply(entries: [ModelCatalogEntry], fetchedAt: Date) {
        self.entries = ModelCatalog.displayEntries(entries)
        freshness = .live(fetchedAt: fetchedAt)
        isLoading = false
        lastFetchFailed = false
        hasCompletedFetch = true
    }

    /// Records a failed fetch, keeping any earlier response but demoting it to stale.
    mutating func applyFailure() {
        isLoading = false
        lastFetchFailed = true
        hasCompletedFetch = true

        switch freshness {
        case .never:
            break
        case .live(let fetchedAt), .stale(let fetchedAt):
            freshness = .stale(fetchedAt: fetchedAt)
        }
    }

    /// Drops everything, e.g. when the proxy stops and nothing on screen can be trusted.
    mutating func reset() {
        self = ModelCatalogState()
    }
}

nonisolated enum ModelCatalogError: LocalizedError, Equatable {
    /// No running proxy to ask, so no catalog can be fetched.
    case proxyUnavailable

    var errorDescription: String? {
        switch self {
        case .proxyUnavailable:
            return "The proxy is not available."
        }
    }
}

nonisolated enum ModelCatalog {

    /// Decodes an OpenAI-compatible `/v1/models` response body.
    ///
    /// The result mirrors the response exactly: no defaults are substituted and
    /// no entries are added or dropped.
    static func parse(_ data: Data) throws -> [ModelCatalogEntry] {
        struct ModelsResponse: Decodable {
            struct ModelItem: Decodable {
                let id: String
                let owned_by: String?
            }
            let data: [ModelItem]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { ModelCatalogEntry(id: $0.id, owner: $0.owned_by) }
    }

    /// Prepares entries for display: deduplicated by ID (first occurrence wins,
    /// matching the proxy registry's own by-ID deduplication) and sorted by ID.
    static func displayEntries(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var seen = Set<String>()
        return entries
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Maps catalog entries onto the agent-setup model list.
    ///
    /// Preserves the historical `owned_by ?? "openai"` provider default that
    /// `AgentConfigurationService.fetchAvailableModels(config:)` — and through it
    /// the agent-config sheet, the warmup sheet and the fallback screen — rely on
    /// (the GitHub Copilot filter matches on `provider == "github-copilot"`).
    static func agentSetupModels(from entries: [ModelCatalogEntry]) -> [AvailableModel] {
        entries.map { entry in
            AvailableModel(
                id: entry.id,
                name: entry.id,
                provider: entry.owner ?? "openai",
                isDefault: false
            )
        }
    }
}
