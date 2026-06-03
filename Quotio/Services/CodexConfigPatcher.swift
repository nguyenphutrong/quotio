//
//  CodexConfigPatcher.swift
//  Quotio
//

import Foundation

nonisolated struct CodexConfigSnapshot: Sendable {
    let baseURL: String?
    let apiKey: String?
    let model: String?
    let isProxyConfigured: Bool
}

nonisolated struct CodexConfigPatcher {
    struct PreparedConfig: Sendable {
        let configTOML: String
        let catalogJSON: String
        let configPath: String
        let catalogPath: String
        let selectedModel: String
        let modelsConfigured: Int
    }

    struct InstallResult: Sendable {
        let configPath: String
        let catalogPath: String
        let backupPath: String?
        let modelsConfigured: Int
    }

    struct RestoreResult: Sendable {
        let configPath: String
        let backupPath: String?
    }

    enum PatcherError: LocalizedError {
        case malformedManagedBlock
        case invalidCatalogJSON

        var errorDescription: String? {
            switch self {
            case .malformedManagedBlock:
                return "Quotio-managed Codex config block is incomplete. Fix ~/.codex/config.toml before applying changes."
            case .invalidCatalogJSON:
                return "Failed to generate Codex model catalog."
            }
        }
    }

    static let providerID = "quotio"
    private static let legacyProviderID = "cliproxyapi"
    private static let managedBegin = "# >>> quotio codex managed >>>"
    private static let managedEnd = "# <<< quotio codex managed <<<"
    private static let previousTopLevelPrefix = "# quotio previous-top-level = "
    private static let managedTopLevelKeys: Set<String> = [
        "model",
        "model_provider",
        "model_catalog_json",
        "model_reasoning_effort"
    ]

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let runtimeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        runtimeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.runtimeDirectory = runtimeDirectory ?? AppRuntimeIdentity
            .applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("Codex", isDirectory: true)
    }

    var configURL: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    var catalogURL: URL {
        runtimeDirectory.appendingPathComponent("custom_model_catalog.json")
    }

    func readSnapshot() -> CodexConfigSnapshot? {
        guard fileManager.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        var activeProvider: String?
        var model: String?
        var baseURL: String?
        var apiKey: String?
        var currentSection: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if let section = parseTOMLSectionName(from: trimmed) {
                currentSection = section
                continue
            }

            if currentSection == nil {
                if trimmed.hasPrefix("model =") {
                    model = extractTOMLValue(from: trimmed)
                } else if trimmed.hasPrefix("model_provider =") {
                    activeProvider = extractTOMLValue(from: trimmed)
                }
            } else if currentSection == "model_providers.\(Self.providerID)" ||
                        currentSection == "model_providers.\(Self.legacyProviderID)" {
                if trimmed.hasPrefix("base_url") {
                    baseURL = extractTOMLValue(from: trimmed)
                } else if trimmed.hasPrefix("experimental_bearer_token") {
                    apiKey = extractTOMLValue(from: trimmed)
                }
            }
        }

        let providerIsQuotio = activeProvider == Self.providerID || activeProvider == Self.legacyProviderID
        let proxyURLIsLocal = baseURL?.contains("127.0.0.1") == true || baseURL?.contains("localhost") == true
        let hasManagedBlock = content.contains(Self.managedBegin)

        return CodexConfigSnapshot(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            isProxyConfigured: providerIsQuotio || proxyURLIsLocal || hasManagedBlock
        )
    }

    func makePreparedConfig(config: AgentConfiguration, availableModels: [AvailableModel]) throws -> PreparedConfig {
        let selectedModel = config.modelSlots[.sonnet] ?? "gpt-5-codex"
        let catalogJSON = try buildCatalogJSON(
            models: availableModels,
            selectedModel: selectedModel
        )
        let existingContent = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let mergedConfig = try installConfigContent(
            existingContent: existingContent,
            selectedModel: selectedModel,
            proxyURL: config.proxyURL,
            apiKey: config.apiKey,
            catalogPath: catalogURL.path
        )

        return PreparedConfig(
            configTOML: mergedConfig,
            catalogJSON: catalogJSON,
            configPath: configURL.path,
            catalogPath: catalogURL.path,
            selectedModel: selectedModel,
            modelsConfigured: max(1, availableModels.isEmpty ? AvailableModel.allModels.count : availableModels.count)
        )
    }

    func install(_ prepared: PreparedConfig) throws -> InstallResult {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let backupPath = try backupConfigIfNeeded()

        try prepared.catalogJSON.write(to: catalogURL, atomically: true, encoding: .utf8)
        try prepared.configTOML.write(to: configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        return InstallResult(
            configPath: configURL.path,
            catalogPath: catalogURL.path,
            backupPath: backupPath,
            modelsConfigured: prepared.modelsConfigured
        )
    }

    func makeRestoredConfigContent() throws -> String? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }
        let content = try String(contentsOf: configURL, encoding: .utf8)
        return try restoreConfigContent(content)
    }

    func restoreDefaultConfig() throws -> RestoreResult {
        guard let restored = try makeRestoredConfigContent() else {
            return RestoreResult(configPath: configURL.path, backupPath: nil)
        }

        let backupPath = try backupConfigIfNeeded()

        try restored.write(to: configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return RestoreResult(configPath: configURL.path, backupPath: backupPath)
    }

    func switchActiveModel(to model: String) throws {
        guard fileManager.fileExists(atPath: configURL.path) else { return }
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let updated = rewriteManagedModel(content, model: model)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func backupConfigIfNeeded() throws -> String? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }

        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.backup.\(Int(Date().timeIntervalSince1970))")

        do {
            try fileManager.copyItem(at: configURL, to: backupURL)
            return backupURL.path
        } catch {
            NSLog("[CodexConfigPatcher] Failed to create backup at \(backupURL.path): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Merge/Restore

    private func installConfigContent(
        existingContent: String,
        selectedModel: String,
        proxyURL: String,
        apiKey: String,
        catalogPath: String
    ) throws -> String {
        let cleanedManaged = try removeManagedBlocks(from: existingContent)
        let currentTopLevel = extractTopLevelKeyLines(from: cleanedManaged, keys: Self.managedTopLevelKeys)
        let currentProvider = topLevelProvider(in: currentTopLevel)
        let currentLooksQuotioManaged = currentProvider == Self.providerID || currentProvider == Self.legacyProviderID
        let previousTopLevel = currentTopLevel.isEmpty || currentLooksQuotioManaged
            ? managedPreviousTopLevel(from: existingContent)
            : currentTopLevel

        var cleaned = removeTopLevelKeys(from: cleanedManaged, keys: Self.managedTopLevelKeys)
        cleaned = removeProviderSections(from: cleaned, providerIDs: [Self.providerID, Self.legacyProviderID])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let blocks = managedBlocks(
            model: selectedModel,
            proxyURL: proxyURL,
            apiKey: apiKey,
            catalogPath: catalogPath,
            previousTopLevel: previousTopLevel
        )

        if cleaned.isEmpty {
            return blocks.top + "\n" + blocks.provider
        }

        return blocks.top + "\n" + cleaned + "\n\n" + blocks.provider
    }

    private func restoreConfigContent(_ content: String) throws -> String {
        let previousTopLevel = managedPreviousTopLevel(from: content)
        var restored = try removeManagedBlocks(from: content)
        let currentTopLevel = extractTopLevelKeyLines(from: restored, keys: Self.managedTopLevelKeys)
        let currentProvider = topLevelProvider(in: currentTopLevel)
        if currentProvider == Self.providerID || currentProvider == Self.legacyProviderID {
            restored = removeTopLevelKeys(from: restored, keys: Self.managedTopLevelKeys)
        }
        restored = removeProviderSections(from: restored, providerIDs: [Self.providerID, Self.legacyProviderID])
        restored = restoreMissingTopLevelKeys(
            in: restored.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
            previousTopLevel: previousTopLevel
        )
        return restored.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func managedBlocks(
        model: String,
        proxyURL: String,
        apiKey: String,
        catalogPath: String,
        previousTopLevel: [String: String]
    ) -> (top: String, provider: String) {
        let metadata = metadataLine(previousTopLevel)
        let top = """
        \(Self.managedBegin)
        \(metadata)model = "\(escapeTOMLString(model))"
        model_provider = "\(Self.providerID)"
        model_catalog_json = "\(escapeTOMLString(catalogPath))"
        model_reasoning_effort = "high"
        \(Self.managedEnd)
        """

        let provider = """
        \(Self.managedBegin)
        [model_providers.\(Self.providerID)]
        name = "Quotio"
        base_url = "\(escapeTOMLString(proxyURL))"
        wire_api = "responses"
        experimental_bearer_token = "\(escapeTOMLString(apiKey))"
        request_max_retries = 3
        stream_max_retries = 3
        stream_idle_timeout_ms = 600000
        \(Self.managedEnd)
        """

        return (top, provider)
    }

    private func metadataLine(_ previousTopLevel: [String: String]) -> String {
        guard !previousTopLevel.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: previousTopLevel, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return Self.previousTopLevelPrefix + json + "\n"
    }

    private func removeManagedBlocks(from text: String) throws -> String {
        var output = text

        while let beginRange = output.range(of: Self.managedBegin) {
            guard let endRange = output.range(of: Self.managedEnd, range: beginRange.upperBound..<output.endIndex) else {
                throw PatcherError.malformedManagedBlock
            }

            var removalEnd = endRange.upperBound
            if removalEnd < output.endIndex, output[removalEnd].isNewline {
                removalEnd = output.index(after: removalEnd)
            }
            output.removeSubrange(beginRange.lowerBound..<removalEnd)
        }

        return output
    }

    private func removeTopLevelKeys(from text: String, keys: Set<String>) -> String {
        var output: [String] = []
        var inTopLevel = true

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if parseTOMLSectionName(from: trimmed) != nil {
                inTopLevel = false
            }

            if inTopLevel, let key = topLevelKey(from: trimmed), keys.contains(key) {
                continue
            }

            output.append(line)
        }

        return output.joined(separator: "\n")
    }

    private func removeProviderSections(from text: String, providerIDs: [String]) -> String {
        var output: [String] = []
        var skippedSection: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let section = parseTOMLSectionName(from: trimmed) {
                skippedSection = providerIDs
                    .map { "model_providers.\($0)" }
                    .first { section == $0 || section.hasPrefix($0 + ".") }

                if skippedSection != nil {
                    continue
                }
            }

            if skippedSection == nil {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private func extractTopLevelKeyLines(from text: String, keys: Set<String>) -> [String: String] {
        var found: [String: String] = [:]
        var inTopLevel = true

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if parseTOMLSectionName(from: trimmed) != nil {
                inTopLevel = false
            }

            guard inTopLevel,
                  let key = topLevelKey(from: trimmed),
                  keys.contains(key) else {
                continue
            }

            found[key] = line
        }

        return found
    }

    private func topLevelProvider(in keyLines: [String: String]) -> String? {
        guard let line = keyLines["model_provider"] else { return nil }
        return extractTOMLValue(from: line.trimmingCharacters(in: .whitespaces))
    }

    private func managedPreviousTopLevel(from text: String) -> [String: String] {
        var inManagedBlock = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == Self.managedBegin {
                inManagedBlock = true
                continue
            }
            if trimmed == Self.managedEnd {
                inManagedBlock = false
                continue
            }

            guard inManagedBlock, trimmed.hasPrefix(Self.previousTopLevelPrefix) else {
                continue
            }

            let encoded = String(trimmed.dropFirst(Self.previousTopLevelPrefix.count))
            guard let data = encoded.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }

            return payload.filter { Self.managedTopLevelKeys.contains($0.key) }
        }

        return [:]
    }

    private func restoreMissingTopLevelKeys(in text: String, previousTopLevel: [String: String]) -> String {
        guard !previousTopLevel.isEmpty else { return text }
        let current = extractTopLevelKeyLines(from: text, keys: Self.managedTopLevelKeys)
        let restoredLines = ["model", "model_provider", "model_catalog_json", "model_reasoning_effort"]
            .compactMap { key -> String? in
                guard current[key] == nil else { return nil }
                return previousTopLevel[key]
            }

        guard !restoredLines.isEmpty else { return text }
        return restoredLines.joined(separator: "\n") + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func rewriteManagedModel(_ content: String, model: String) -> String {
        var output: [String] = []
        var inManagedBlock = false
        var inQuotioProvider = false
        var didRewriteModel = false
        var didRewriteProviderName = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == Self.managedBegin {
                inManagedBlock = true
                inQuotioProvider = false
                output.append(line)
                continue
            }

            if trimmed == Self.managedEnd {
                inManagedBlock = false
                inQuotioProvider = false
                output.append(line)
                continue
            }

            if inManagedBlock, parseTOMLSectionName(from: trimmed) == "model_providers.\(Self.providerID)" {
                inQuotioProvider = true
            }

            if inManagedBlock, !inQuotioProvider, !didRewriteModel, trimmed.hasPrefix("model =") {
                output.append("model = \"\(escapeTOMLString(model))\"")
                didRewriteModel = true
                continue
            }

            if inManagedBlock, inQuotioProvider, !didRewriteProviderName, trimmed.hasPrefix("name =") {
                output.append("name = \"Quotio\"")
                didRewriteProviderName = true
                continue
            }

            output.append(line)
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Catalog

    private func buildCatalogJSON(models: [AvailableModel], selectedModel: String) throws -> String {
        var catalogModels = models.isEmpty ? AvailableModel.allModels : models
        if !catalogModels.contains(where: { $0.name == selectedModel || $0.id == selectedModel }) {
            catalogModels.insert(
                AvailableModel(id: selectedModel, name: selectedModel, provider: "quotio", isDefault: false),
                at: 0
            )
        }

        let entries = catalogModels.enumerated().map { index, model in
            catalogEntry(model: model, isDefault: model.name == selectedModel || model.id == selectedModel, index: index)
        }

        let payload: [String: Any] = ["models": entries]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )

        guard let json = String(data: data, encoding: .utf8) else {
            throw PatcherError.invalidCatalogJSON
        }

        return json + "\n"
    }

    private func catalogEntry(model: AvailableModel, isDefault: Bool, index: Int) -> [String: Any] {
        let context = defaultContext(for: model.name)
        let compact = max(8_000, Int(Double(context) * 0.8))
        let truncation = min(64_000, max(8_000, Int(Double(context) * 0.32)))
        let prettyName = Self.formatModelName(model.name)

        return [
            "slug": model.name,
            "display_name": prettyName,
            "description": "\(prettyName) via Quotio.",
            "context_window": context,
            "max_context_window": context,
            "auto_compact_token_limit": compact,
            "truncation_policy": ["mode": "tokens", "limit": truncation],
            "default_reasoning_level": defaultReasoningEffort(for: model.name),
            "supported_reasoning_levels": [
                ["effort": "low", "description": "Faster, lighter reasoning"],
                ["effort": "medium", "description": "Balanced speed and reasoning"],
                ["effort": "high", "description": "Deeper reasoning"],
                ["effort": "xhigh", "description": "Maximum reasoning where supported"]
            ],
            "default_reasoning_summary": "none",
            "reasoning_summary_format": "none",
            "supports_reasoning_summaries": false,
            "default_verbosity": "low",
            "support_verbosity": false,
            "apply_patch_tool_type": "freeform",
            "web_search_tool_type": "text_and_image",
            "supports_search_tool": false,
            "supports_parallel_tool_calls": true,
            "experimental_supported_tools": [],
            "input_modalities": ["text", "image"],
            "supports_image_detail_original": true,
            "shell_type": "shell_command",
            "visibility": "list",
            "minimal_client_version": "0.0.1",
            "supported_in_api": true,
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
            "priority": max(1, 1000 - index),
            "prefer_websockets": false,
            "available_in_plans": ["free", "plus", "pro", "team", "business", "enterprise"],
            "base_instructions": "You are a coding agent running in Codex through Quotio.",
            "model_messages": [
                "instructions_template": "You are Codex running on {model_name} through Quotio. Be a helpful, direct coding collaborator.",
                "instructions_variables": ["model_name": prettyName]
            ],
            "isDefault": isDefault
        ]
    }

    static func formatModelName(_ raw: String) -> String {
        let segments = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if segments.count >= 2 {
            let provider = formatSegment(segments[0])
            let rest = segments.dropFirst().map(formatSegment).joined(separator: " / ")
            return "[\(provider)] \(rest)"
        }
        return formatSegment(raw)
    }

    private static func formatSegment(_ segment: String) -> String {
        let tokens = segment
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return segment }

        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isAllDigits(token), index + 1 < tokens.count, isAllDigits(tokens[index + 1]) {
                result.append("\(token).\(tokens[index + 1])")
                index += 2
            } else {
                result.append(formatToken(token))
                index += 1
            }
        }
        return result.joined(separator: " ")
    }

    private static func isAllDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isNumber }
    }

    private static let tokenAliases: [String: String] = [
        "gpt": "GPT",
        "oss": "OSS",
        "cli": "CLI",
        "api": "API",
        "ai": "AI",
        "llm": "LLM",
        "github": "GitHub",
        "openai": "OpenAI",
        "google": "Google",
        "anthropic": "Anthropic",
        "antigravity": "Antigravity",
        "claude": "Claude",
        "gemini": "Gemini",
        "copilot": "Copilot",
        "cursor": "Cursor",
        "codex": "Codex",
        "trae": "Trae",
        "quotio": "Quotio"
    ]

    private static func formatToken(_ token: String) -> String {
        let lower = token.lowercased()
        if let alias = tokenAliases[lower] {
            return alias
        }
        guard let first = token.first else { return token }
        return first.uppercased() + token.dropFirst()
    }

    private func defaultContext(for model: String) -> Int {
        let lower = model.lowercased()
        if lower.contains("claude") { return 200_000 }
        if lower.contains("gpt-5") { return 400_000 }
        if lower.contains("gemini") { return 1_000_000 }
        return 128_000
    }

    private func defaultReasoningEffort(for model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("xhigh") || lower.contains("x-high") { return "xhigh" }
        if lower.contains("high") { return "high" }
        if lower.contains("low") { return "low" }
        return "medium"
    }

    // MARK: - TOML Helpers

    private func parseTOMLSectionName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }

        if trimmed.hasPrefix("[[") {
            guard let closeRange = trimmed.range(of: "]]") else { return nil }
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let section = String(trimmed[start..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            return section.isEmpty ? nil : section
        }

        guard let closeIndex = trimmed.firstIndex(of: "]") else { return nil }
        let start = trimmed.index(after: trimmed.startIndex)
        guard start <= closeIndex else { return nil }
        let section = String(trimmed[start..<closeIndex]).trimmingCharacters(in: .whitespaces)
        return section.isEmpty ? nil : section
    }

    private func topLevelKey(from line: String) -> String? {
        guard !line.isEmpty,
              !line.hasPrefix("#"),
              let equalIndex = line.firstIndex(of: "=") else {
            return nil
        }
        return String(line[..<equalIndex]).trimmingCharacters(in: .whitespaces)
    }

    private func extractTOMLValue(from line: String) -> String? {
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)

        var inQuotes = false
        var previousWasBackslash = false
        var commentIndex: String.Index?

        for index in value.indices {
            let character = value[index]
            if character == "\"", !previousWasBackslash {
                inQuotes.toggle()
            } else if character == "#", !inQuotes {
                commentIndex = index
                break
            }

            previousWasBackslash = character == "\\" && !previousWasBackslash
        }

        if let commentIndex {
            value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespaces)
        }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }

        return value.isEmpty ? nil : value
    }

    private func escapeTOMLString(_ value: String) -> String {
        var escaped = ""

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }
}
