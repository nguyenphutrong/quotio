//
//  AgentConfigOwnership.swift
//  Quotio - Prove Quotio authored an agent config before reverting it
//
//  A base URL pointing at `localhost` says an agent talks to *some* local
//  proxy; it does not say the proxy is Quotio's. Users run their own local
//  gateways (LiteLLM, Ollama shims, corporate relays), and reverting those is
//  destroying configuration Quotio never wrote.
//
//  Ownership is therefore established from something Quotio itself authored:
//
//  1. A receipt written when Quotio applied the config (the endpoint plus a
//     fingerprint of the API key Quotio issued). If the endpoint and key on
//     disk still match the receipt, the bytes there are Quotio's. If a receipt
//     exists but no longer matches, the user changed it by hand and Quotio must
//     keep its hands off.
//  2. Failing that, a Quotio-authored marker that no other tool would write -
//     the `cliproxyapi` provider Codex CLI is pointed at, or OpenCode's
//     `provider.quotio` entry. This is the fallback for configs applied before
//     receipts existed.
//
//  Agents with neither (Claude Code, Amp CLI, Factory Droid all use
//  vendor-standard keys with nothing Quotio-specific in them) are left alone
//  when no receipt is present. Skipping a revert is recoverable; deleting a
//  config Quotio did not write is not.
//

import CryptoKit
import Foundation

// MARK: - Receipt

/// What Quotio wrote for one agent, recorded at the moment it wrote it.
///
/// The API key is stored only as a SHA-256 fingerprint: the check needs to
/// compare keys, not read them back, so the secret never lands in `UserDefaults`.
nonisolated struct AgentConfigOwnershipRecord: Codable, Sendable, Equatable {
    let agent: CLIAgent
    /// Endpoint Quotio wrote, normalised (no `/v1` suffix, no trailing slash).
    let baseURL: String
    /// SHA-256 hex of the API key Quotio wrote.
    let apiKeyFingerprint: String
    /// `false` when Quotio created the agent's primary config file itself, i.e.
    /// there was no file there before. Recorded for issue #128's "remove it if
    /// Quotio created it" semantics; see the PR notes for the current scope.
    let primaryConfigExisted: Bool
    let recordedAt: Date

    static func fingerprint(ofAPIKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Trims `/v1` and trailing slashes so the value written by setup and the
    /// value read back from disk compare equal regardless of which form the
    /// agent's file format stores.
    static func normalizedBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") { value.removeLast(3) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    init(agent: CLIAgent, baseURL: String, apiKey: String, primaryConfigExisted: Bool, recordedAt: Date = Date()) {
        self.agent = agent
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.apiKeyFingerprint = Self.fingerprint(ofAPIKey: apiKey)
        self.primaryConfigExisted = primaryConfigExisted
        self.recordedAt = recordedAt
    }
}

// MARK: - Receipt Storage

/// Persists one receipt per agent.
///
/// `@unchecked` only because `UserDefaults` is not formally `Sendable`; it is
/// documented as thread-safe and this type adds no mutable state of its own.
nonisolated struct AgentConfigOwnershipStore: @unchecked Sendable {
    static let storageKey = "agentConfigOwnershipReceipts"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(for agent: CLIAgent) -> AgentConfigOwnershipRecord? {
        all()[agent.rawValue]
    }

    func save(_ record: AgentConfigOwnershipRecord) {
        var records = all()
        records[record.agent.rawValue] = record
        persist(records)
    }

    func clear(agent: CLIAgent) {
        var records = all()
        guard records.removeValue(forKey: agent.rawValue) != nil else { return }
        persist(records)
    }

    private func all() -> [String: AgentConfigOwnershipRecord] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: AgentConfigOwnershipRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ records: [String: AgentConfigOwnershipRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Decision

nonisolated enum AgentConfigOwnershipProof: String, Sendable, Equatable {
    /// The endpoint and API key on disk still match the receipt Quotio wrote.
    case receipt
    /// No receipt, but a marker only Quotio writes is still in the file.
    case authoredMarker
}

nonisolated enum AgentConfigOwnershipDoubt: String, Sendable, Equatable {
    /// Nothing on disk, or the agent is not pointed at any proxy.
    case notConfigured
    /// A receipt exists but the file no longer holds what Quotio wrote.
    case externallyModified
    /// No receipt and no Quotio-authored marker: ownership cannot be shown.
    case noEvidence
}

nonisolated enum AgentConfigOwnership: Sendable, Equatable {
    case owned(AgentConfigOwnershipProof)
    case notOwned(AgentConfigOwnershipDoubt)

    var isOwned: Bool {
        if case .owned = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .owned(let proof): return proof.rawValue
        case .notOwned(let doubt): return doubt.rawValue
        }
    }
}

// MARK: - On-Disk State

/// One endpoint/credential pair found in an agent's config.
///
/// Most agents hold exactly one. Factory Droid holds an array of
/// `custom_models`, so it can yield several - only the entries matching the
/// receipt belong to Quotio.
nonisolated struct AgentConfigEndpoint: Sendable, Equatable {
    let baseURL: String?
    let apiKey: String?
}

nonisolated struct AgentOnDiskConfig: Sendable, Equatable {
    var endpoints: [AgentConfigEndpoint] = []
    /// A key or section only Quotio writes is present.
    var hasAuthoredMarker: Bool = false

    var isEmpty: Bool { endpoints.isEmpty && !hasAuthoredMarker }
}

// MARK: - Verifier

/// Reads what is actually on disk for an agent and decides whether Quotio may
/// modify it. The home directory is injectable so tests never read or write the
/// developer's real agent configs.
/// `@unchecked` only because `FileManager` is not formally `Sendable`; reads are
/// thread-safe and this type adds no mutable state of its own.
nonisolated struct AgentConfigOwnershipVerifier: @unchecked Sendable {
    private let homeDirectory: String
    private let fileManager: FileManager

    init(homeDirectory: String? = nil, fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser.path
        self.fileManager = fileManager
    }

    /// Decide whether Quotio wrote the config currently on disk for `agent`.
    func ownership(of agent: CLIAgent, record: AgentConfigOwnershipRecord?) -> AgentConfigOwnership {
        let onDisk = readOnDiskConfig(for: agent)

        guard !onDisk.isEmpty else { return .notOwned(.notConfigured) }

        if let record {
            let matches = onDisk.endpoints.contains { endpoint in
                guard let baseURL = endpoint.baseURL, let apiKey = endpoint.apiKey else { return false }
                return AgentConfigOwnershipRecord.normalizedBaseURL(baseURL) == record.baseURL
                    && AgentConfigOwnershipRecord.fingerprint(ofAPIKey: apiKey) == record.apiKeyFingerprint
            }
            return matches ? .owned(.receipt) : .notOwned(.externallyModified)
        }

        // No receipt: fall back to a marker no other tool writes.
        return onDisk.hasAuthoredMarker ? .owned(.authoredMarker) : .notOwned(.noEvidence)
    }

    // MARK: On-disk readers

    func readOnDiskConfig(for agent: CLIAgent) -> AgentOnDiskConfig {
        switch agent {
        case .claudeCode: return readClaudeCode()
        case .codexCLI: return readCodex()
        case .ampCLI: return readAmp()
        case .openCode: return readOpenCode()
        case .factoryDroid: return readFactoryDroid()
        }
    }

    /// `~/.claude/settings.json`. `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`
    /// are Anthropic's own variable names, so there is no Quotio marker here -
    /// only the receipt can establish ownership.
    private func readClaudeCode() -> AgentOnDiskConfig {
        guard let json = readJSONObject(at: "\(homeDirectory)/.claude/settings.json"),
              let env = json["env"] as? [String: String] else {
            return AgentOnDiskConfig()
        }

        guard let baseURL = env["ANTHROPIC_BASE_URL"] else { return AgentOnDiskConfig() }

        return AgentOnDiskConfig(
            endpoints: [AgentConfigEndpoint(baseURL: baseURL, apiKey: env["ANTHROPIC_AUTH_TOKEN"])],
            hasAuthoredMarker: false
        )
    }

    /// `~/.codex/config.toml` plus `~/.codex/auth.json`. The provider id
    /// `cliproxyapi` is written by Quotio and by nothing else, so it doubles as
    /// the marker.
    private func readCodex() -> AgentOnDiskConfig {
        let configPath = "\(homeDirectory)/.codex/config.toml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return AgentOnDiskConfig()
        }

        var baseURL: String?
        var inCliproxySection = false
        var hasMarker = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") {
                inCliproxySection = trimmed.hasPrefix("[model_providers.cliproxyapi]")
                if inCliproxySection { hasMarker = true }
                continue
            }

            if trimmed.hasPrefix("model_provider") && trimmed.contains("cliproxyapi") {
                hasMarker = true
                continue
            }

            if inCliproxySection, trimmed.hasPrefix("base_url"), let value = tomlValue(from: trimmed) {
                baseURL = value
            }
        }

        guard hasMarker || baseURL != nil else { return AgentOnDiskConfig() }

        // The key lives in the sibling auth.json, which setup writes at the same time.
        let apiKey = (readJSONObject(at: "\(homeDirectory)/.codex/auth.json")?["OPENAI_API_KEY"]) as? String

        return AgentOnDiskConfig(
            endpoints: [AgentConfigEndpoint(baseURL: baseURL, apiKey: apiKey)],
            hasAuthoredMarker: hasMarker
        )
    }

    /// `~/.config/amp/settings.json` plus `~/.local/share/amp/secrets.json`.
    /// `amp.url` is Amp's own key, so there is no marker - receipt only.
    private func readAmp() -> AgentOnDiskConfig {
        guard let settings = readJSONObject(at: "\(homeDirectory)/.config/amp/settings.json"),
              let baseURL = settings["amp.url"] as? String else {
            return AgentOnDiskConfig()
        }

        // Setup stores the key under "apiKey@<amp.url>" in the data directory.
        let secrets = readJSONObject(at: "\(homeDirectory)/.local/share/amp/secrets.json")
        let apiKey = secrets?["apiKey@\(baseURL)"] as? String

        return AgentOnDiskConfig(
            endpoints: [AgentConfigEndpoint(baseURL: baseURL, apiKey: apiKey)],
            hasAuthoredMarker: false
        )
    }

    /// `~/.config/opencode/opencode.json`. The provider is literally keyed
    /// `quotio`, which is as unambiguous a marker as it gets.
    private func readOpenCode() -> AgentOnDiskConfig {
        guard let json = readJSONObject(at: "\(homeDirectory)/.config/opencode/opencode.json"),
              let providers = json["provider"] as? [String: Any],
              let quotio = providers["quotio"] as? [String: Any] else {
            return AgentOnDiskConfig()
        }

        let options = quotio["options"] as? [String: Any]

        return AgentOnDiskConfig(
            endpoints: [
                AgentConfigEndpoint(
                    baseURL: options?["baseURL"] as? String,
                    apiKey: options?["apiKey"] as? String
                )
            ],
            hasAuthoredMarker: true
        )
    }

    /// `~/.factory/config.json`. Entries in `custom_models` carry no Quotio
    /// field, so every localhost entry looks alike - the receipt is the only
    /// way to tell Quotio's entries from a user's own local model.
    private func readFactoryDroid() -> AgentOnDiskConfig {
        guard let json = readJSONObject(at: "\(homeDirectory)/.factory/config.json"),
              let customModels = json["custom_models"] as? [[String: Any]],
              !customModels.isEmpty else {
            return AgentOnDiskConfig()
        }

        return AgentOnDiskConfig(
            endpoints: customModels.map {
                AgentConfigEndpoint(baseURL: $0["base_url"] as? String, apiKey: $0["api_key"] as? String)
            },
            hasAuthoredMarker: false
        )
    }

    // MARK: Parsing helpers

    private func readJSONObject(at path: String) -> [String: Any]? {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func tomlValue(from line: String) -> String? {
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        var value = String(line[line.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
