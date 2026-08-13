//
//  AgentConfigurationService.swift
//  Quotio - Generate agent configurations
//

import Foundation

actor AgentConfigurationService {
    private let fileManager = FileManager.default
    
    // MARK: - Saved Configuration Models
    
    /// Represents the currently saved configuration for an agent
    struct SavedAgentConfig: Sendable {
        let baseURL: String?
        let apiKey: String?
        let modelSlots: [ModelSlot: String]
        let isProxyConfigured: Bool
        let backupFiles: [BackupFile]
        /// Reasoning effort read from Codex CLI's `model_reasoning_effort` (Codex only).
        var reasoningEffort: CodexReasoningEffort? = nil
    }
    
    /// Represents a backup file that can be restored
    struct BackupFile: Identifiable, Sendable {
        let path: String
        let timestamp: Date
        let agent: CLIAgent
        
        var id: String { path }
        
        // Use static formatter for performance
        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
        
        var displayName: String {
            Self.dateFormatter.string(from: timestamp)
        }
    }
    
    // MARK: - Read Existing Configuration
    
    /// Read the current saved configuration for an agent
    func readConfiguration(agent: CLIAgent) -> SavedAgentConfig? {
        switch agent {
        case .claudeCode:
            return readClaudeCodeConfig()
        case .codexCLI:
            return readCodexConfig()
        case .ampCLI:
            return readAmpConfig()
        case .openCode:
            return readOpenCodeConfig()
        case .factoryDroid:
            return readFactoryDroidConfig()
        }
    }
    
    /// List available backup files for an agent
    func listBackups(agent: CLIAgent) -> [BackupFile] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var backups: [BackupFile] = []
        
        for configPath in agent.configPaths {
            let expandedPath = configPath.replacingOccurrences(of: "~", with: home)
            let directory = (expandedPath as NSString).deletingLastPathComponent
            let filename = (expandedPath as NSString).lastPathComponent
            
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            
            for file in contents {
                if file.hasPrefix(filename + ".backup.") {
                    let fullPath = "\(directory)/\(file)"
                    // Extract timestamp from filename (e.g., settings.json.backup.1736840000)
                    if let timestampStr = file.components(separatedBy: ".backup.").last,
                       let timestamp = Double(timestampStr) {
                        let date = Date(timeIntervalSince1970: timestamp)
                        backups.append(BackupFile(path: fullPath, timestamp: date, agent: agent))
                    }
                }
            }
        }
        
        // Sort by most recent first
        return backups.sorted { $0.timestamp > $1.timestamp }
    }
    
    /// Restore configuration from a backup file
    func restoreFromBackup(_ backup: BackupFile) throws {
        // Determine the original config path from the backup path
        // e.g., ~/.claude/settings.json.backup.123 -> ~/.claude/settings.json
        let originalPath = backup.path
            .replacingOccurrences(of: ".backup.\(Int(backup.timestamp.timeIntervalSince1970))", with: "")
        
        // Create a backup of current config before restoring
        if fileManager.fileExists(atPath: originalPath) {
            let currentBackupPath = "\(originalPath).backup.\(Int(Date().timeIntervalSince1970))"
            try? fileManager.copyItem(atPath: originalPath, toPath: currentBackupPath)
            try fileManager.removeItem(atPath: originalPath)
        }
        
        // Copy backup to original location
        try fileManager.copyItem(atPath: backup.path, toPath: originalPath)
    }
    
    // MARK: - Agent-Specific Read Implementations
    
    private func readClaudeCodeConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.claude/settings.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let env = json["env"] as? [String: String] ?? [:]
        
        let baseURL = env["ANTHROPIC_BASE_URL"]
        let apiKey = env["ANTHROPIC_AUTH_TOKEN"]
        let opusModel = env["ANTHROPIC_DEFAULT_OPUS_MODEL"]
        let sonnetModel = env["ANTHROPIC_DEFAULT_SONNET_MODEL"]
        let haikuModel = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]
        
        var modelSlots: [ModelSlot: String] = [:]
        if let opus = opusModel { modelSlots[.opus] = opus }
        if let sonnet = sonnetModel { modelSlots[.sonnet] = sonnet }
        if let haiku = haikuModel { modelSlots[.haiku] = haiku }
        
        // Check if proxy is configured (localhost or 127.0.0.1 in base URL)
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .claudeCode)
        )
    }
    
    private func readCodexConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.codex/config.toml"
        
        guard fileManager.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        
        // Simple TOML parsing for the values we need
        var baseURL: String?
        var model: String?
        let reasoningEffort = parseTopLevelCodexReasoningEffort(from: content)
        var isProxy = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("base_url") {
                if let value = extractTOMLValue(from: trimmed) {
                    baseURL = value
                    isProxy = value.contains("127.0.0.1") || value.contains("localhost")
                }
            } else if trimmed.hasPrefix("model =") {
                model = extractTOMLValue(from: trimmed)
            } else if trimmed.contains("model_provider") && trimmed.contains("cliproxyapi") {
                isProxy = true
            }
        }
        
        var modelSlots: [ModelSlot: String] = [:]
        if let m = model {
            modelSlots[.sonnet] = m  // Codex uses single model
        }
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: nil,  // API key is in auth.json
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .codexCLI),
            reasoningEffort: reasoningEffort
        )
    }
    
    private func readAmpConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.config/amp/settings.json"
        
        guard fileManager.fileExists(atPath: settingsPath),
              let data = fileManager.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let baseURL = json["amp.url"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: nil,  // API key is in secrets.json
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .ampCLI)
        )
    }
    
    private func readOpenCodeConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.config/opencode/opencode.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Check for quotio provider
        guard let providers = json["provider"] as? [String: Any],
              let quotioProvider = providers["quotio"] as? [String: Any],
              let options = quotioProvider["options"] as? [String: Any] else {
            return SavedAgentConfig(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: listBackups(agent: .openCode)
            )
        }
        
        let baseURL = options["baseURL"] as? String
        let apiKey = options["apiKey"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .openCode)
        )
    }
    
    private func readFactoryDroidConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.factory/config.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        guard let customModels = json["custom_models"] as? [[String: Any]],
              let firstModel = customModels.first else {
            return SavedAgentConfig(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: listBackups(agent: .factoryDroid)
            )
        }
        
        let baseURL = firstModel["base_url"] as? String
        let apiKey = firstModel["api_key"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .factoryDroid)
        )
    }
    
    // MARK: - Helper Functions
    
    private func extractTOMLValue(from line: String) -> String? {
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    
    private func extractExportValue(from line: String) -> String? {
        // Handle: export VAR="value" or export VAR=value
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// Escape a value for use in a TOML basic string.
    /// Handles quotes, backslashes, and ASCII control characters.
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

    func buildManagedCodexTOML(
        model: String,
        proxyURL: String,
        reasoningEffort: CodexReasoningEffort = .defaultEffort
    ) -> String {
        let escapedModel = escapeTOMLString(model)
        let escapedProxyURL = escapeTOMLString(proxyURL)
        // A `custom` effort carries a literal value read from the user's file.
        let escapedReasoningEffort = escapeTOMLString(reasoningEffort.rawValue)

        return """
        # CLIProxyAPI Configuration for Codex CLI
        model_provider = "cliproxyapi"
        model = "\(escapedModel)"
        model_reasoning_effort = "\(escapedReasoningEffort)"

        [model_providers.cliproxyapi]
        name = "cliproxyapi"
        base_url = "\(escapedProxyURL)"
        wire_api = "responses"
        """
    }

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

    private func isCodexManagedTopLevelKey(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equalIndex = trimmed.firstIndex(of: "=") else { return false }
        let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
        return key == "model_provider" || key == "model" || key == "model_reasoning_effort"
    }

    /// Tracks TOML multi-line string state (`"""` / `'''`) across a line-by-line
    /// scan so that text inside a string body is never mistaken for a table
    /// header or a key/value pair.
    private struct CodexTOMLScanner {
        /// Quote character of the multi-line string currently open, or `nil`
        /// when the scanner is at TOML structure level.
        private var openMultilineQuote: Character?

        /// Feeds one line to the scanner.
        /// - Returns: `true` when the line is TOML structure, `false` when it is
        ///   part of a multi-line string body (including its closing delimiter).
        mutating func isStructuralLine(_ line: String) -> Bool {
            let characters = Array(line)
            let startedInsideMultiline = openMultilineQuote != nil
            var index = 0

            while index < characters.count {
                let character = characters[index]

                if let quote = openMultilineQuote {
                    if character == quote, Self.isTriple(characters, at: index, quote: quote) {
                        openMultilineQuote = nil
                        index += 3
                    } else {
                        index += 1
                    }
                    continue
                }

                switch character {
                case "#":
                    // A comment runs to the end of the line.
                    index = characters.count
                case "\"", "'":
                    if Self.isTriple(characters, at: index, quote: character) {
                        openMultilineQuote = character
                        index += 3
                    } else {
                        index = Self.endOfSingleLineString(characters, from: index, quote: character)
                    }
                default:
                    index += 1
                }
            }

            return !startedInsideMultiline
        }

        private static func isTriple(_ characters: [Character], at index: Int, quote: Character) -> Bool {
            guard index + 2 < characters.count else { return false }
            return characters[index + 1] == quote && characters[index + 2] == quote
        }

        private static func endOfSingleLineString(
            _ characters: [Character],
            from index: Int,
            quote: Character
        ) -> Int {
            var cursor = index + 1
            while cursor < characters.count {
                let character = characters[cursor]
                // Literal strings ('...') do not support escapes.
                if quote == "\"", character == "\\" {
                    cursor += 2
                    continue
                }
                if character == quote {
                    return cursor + 1
                }
                cursor += 1
            }
            return characters.count
        }
    }

    /// Reads the **top-level** `model_reasoning_effort` from a Codex `config.toml`.
    ///
    /// `model_reasoning_effort` is a top-level key, but the same key is also legal
    /// under `[profiles.*]` and other tables. Table headers are tracked so a
    /// profile's value is never reported as — and then used to overwrite — the
    /// top-level setting. Returns `nil` when the top-level key is absent, so the
    /// caller keeps its default.
    func parseTopLevelCodexReasoningEffort(from content: String) -> CodexReasoningEffort? {
        var scanner = CodexTOMLScanner()
        var effort: CodexReasoningEffort?

        for line in content.components(separatedBy: .newlines) {
            guard scanner.isStructuralLine(line) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Everything from the first table header on belongs to that table.
            if parseTOMLSectionName(from: trimmed) != nil {
                return effort
            }

            if let value = extractCodexTOMLStringValue(from: trimmed, key: "model_reasoning_effort") {
                effort = CodexReasoningEffort(rawValue: value)
            }
        }

        return effort
    }

    /// Reads the value of a TOML assignment to `key`, tolerating quoted keys,
    /// literal strings and trailing comments. Returns `nil` unless the line is
    /// an assignment to exactly `key` with a value this parser can round-trip.
    private func extractCodexTOMLStringValue(from line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equalIndex = trimmed.firstIndex(of: "=") else { return nil }

        var lineKey = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
        if lineKey.count >= 2, let first = lineKey.first, lineKey.last == first, first == "\"" || first == "'" {
            lineKey = String(lineKey.dropFirst().dropLast())
        }
        guard lineKey == key else { return nil }

        let value = String(trimmed[trimmed.index(after: equalIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return parseCodexTOMLScalarString(value)
    }

    private func parseCodexTOMLScalarString(_ value: String) -> String? {
        let characters = Array(value)
        guard let first = characters.first else { return nil }

        // Multi-line strings are not a value Quotio can safely round-trip.
        if characters.count >= 3, characters[1] == first, characters[2] == first,
           first == "\"" || first == "'" {
            return nil
        }

        if first == "\"" {
            var result = ""
            var index = 1
            while index < characters.count {
                let character = characters[index]
                if character == "\\" {
                    index += 1
                    guard index < characters.count else { return nil }
                    switch characters[index] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    // Don't guess at \u / \b / \f — leave the value untouched.
                    default: return nil
                    }
                    index += 1
                    continue
                }
                if character == "\"" {
                    return result.isEmpty ? nil : result
                }
                result.append(character)
                index += 1
            }
            return nil  // Unterminated string.
        }

        if first == "'" {
            guard let closingIndex = value.dropFirst().firstIndex(of: "'") else { return nil }
            let literal = String(value[value.index(after: value.startIndex)..<closingIndex])
            return literal.isEmpty ? nil : literal
        }

        // Bare value: invalid TOML for a string, but read it leniently rather
        // than discarding what the user wrote.
        let bare = value
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? nil : bare
    }

    private typealias ManagedCodexConfigParts = (topLevel: [String], section: [String])

    private func splitManagedCodexConfig(_ managedConfig: String) -> ManagedCodexConfigParts {
        let lines = managedConfig.components(separatedBy: .newlines)
        guard let sectionStart = lines.firstIndex(where: { parseTOMLSectionName(from: $0) != nil }) else {
            return (lines, [])
        }
        return (Array(lines[..<sectionStart]), Array(lines[sectionStart...]))
    }

    private func extractManagedCodexBanner(from managedConfig: String) -> String? {
        for line in managedConfig.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return trimmed.hasPrefix("#") ? trimmed : nil
        }
        return nil
    }

    private func filterExistingCodexLines(existingContent: String, managedBanner: String?) -> [String] {
        let lines = existingContent.components(separatedBy: .newlines)
        var filteredLines: [String] = []
        var skippingCliproxySection = false
        var hasSeenAnySection = false
        var scanner = CodexTOMLScanner()

        for line in lines {
            // Lines inside a multi-line string body are content, never structure.
            let isStructural = scanner.isStructuralLine(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isStructural, let sectionName = parseTOMLSectionName(from: trimmed) {
                let cliproxySection = "model_providers.cliproxyapi"
                if sectionName == cliproxySection || sectionName.hasPrefix(cliproxySection + ".") {
                    skippingCliproxySection = true
                    continue
                }
                skippingCliproxySection = false
                hasSeenAnySection = true
            }

            if skippingCliproxySection {
                continue
            }

            if let managedBanner, isStructural, !hasSeenAnySection && trimmed == managedBanner {
                continue
            }

            if isStructural, !hasSeenAnySection && isCodexManagedTopLevelKey(trimmed) {
                continue
            }

            filteredLines.append(line)
        }

        while filteredLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            filteredLines.removeLast()
        }

        return filteredLines
    }

    private func composeMergedCodexConfig(filteredLines: [String], managedParts: ManagedCodexConfigParts) -> String {
        var firstSectionIndex = filteredLines.count
        var scanner = CodexTOMLScanner()
        for (index, line) in filteredLines.enumerated() {
            guard scanner.isStructuralLine(line) else { continue }
            if parseTOMLSectionName(from: line) != nil {
                firstSectionIndex = index
                break
            }
        }

        var topLevelLines = Array(filteredLines[..<firstSectionIndex])
        let remainingSections = Array(filteredLines[firstSectionIndex...])

        while topLevelLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            topLevelLines.removeLast()
        }

        var leadingHeaderIndex = 0
        while leadingHeaderIndex < topLevelLines.count {
            let trimmed = topLevelLines[leadingHeaderIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                leadingHeaderIndex += 1
            } else {
                break
            }
        }

        var leadingHeader = Array(topLevelLines[..<leadingHeaderIndex])
        var userTopLevel = Array(topLevelLines[leadingHeaderIndex...])

        while leadingHeader.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            leadingHeader.removeLast()
        }

        while userTopLevel.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            userTopLevel.removeFirst()
        }
        while userTopLevel.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            userTopLevel.removeLast()
        }

        var merged: [String] = []
        if !leadingHeader.isEmpty {
            merged.append(contentsOf: leadingHeader)
        }

        if !merged.isEmpty && merged.last?.isEmpty == false {
            merged.append("")
        }
        merged.append(contentsOf: managedParts.topLevel)

        if !userTopLevel.isEmpty {
            if merged.last?.isEmpty == false {
                merged.append("")
            }
            merged.append(contentsOf: userTopLevel)
        }

        if merged.last?.isEmpty == false {
            merged.append("")
        }
        merged.append(contentsOf: managedParts.section)

        if !remainingSections.isEmpty {
            if merged.last?.isEmpty == false {
                merged.append("")
            }
            merged.append(contentsOf: remainingSections)
        }

        return merged
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func mergeCodexConfig(existingContent: String, managedConfig: String) -> String {
        let managedBanner = extractManagedCodexBanner(from: managedConfig)
        let managedParts = splitManagedCodexConfig(managedConfig)
        let filteredLines = filterExistingCodexLines(existingContent: existingContent, managedBanner: managedBanner)
        return composeMergedCodexConfig(filteredLines: filteredLines, managedParts: managedParts)
    }
    
    func generateConfiguration(
        agent: CLIAgent,
        config: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly,
        detectionService: AgentDetectionService,
        availableModels: [AvailableModel] = []
    ) async throws -> AgentConfigResult {
        
        // Check if we should generate default (non-proxy) configuration
        if config.setupMode == .defaultSetup {
            return try await generateDefaultConfiguration(agent: agent, mode: mode)
        }

        switch agent {
        case .claudeCode:
            return generateClaudeCodeConfig(config: config, mode: mode, storageOption: storageOption)

        case .codexCLI:
            return try await generateCodexConfig(config: config, mode: mode)

        case .ampCLI:
            return try await generateAmpConfig(config: config, mode: mode)

        case .openCode:
            return generateOpenCodeConfig(config: config, mode: mode, availableModels: availableModels)

        case .factoryDroid:
            return generateFactoryDroidConfig(config: config, mode: mode, availableModels: availableModels)
        }
    }
    
    // MARK: - Generate Default (Non-Proxy) Configuration
    
    /// Generates configuration that removes Quotio proxy settings while preserving user settings
    private func generateDefaultConfiguration(agent: CLIAgent, mode: ConfigurationMode) async throws -> AgentConfigResult {
        switch agent {
        case .claudeCode:
            return generateClaudeCodeDefaultConfig(mode: mode)
        case .codexCLI:
            return generateCodexDefaultConfig(mode: mode)
        case .ampCLI:
            return generateAmpDefaultConfig(mode: mode)
        case .openCode:
            return generateOpenCodeDefaultConfig(mode: mode)
        case .factoryDroid:
            return generateFactoryDroidDefaultConfig(mode: mode)
        }
    }
    
    private func generateClaudeCodeDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"
        
        // Keys to remove (Quotio-managed proxy config)
        let keysToRemove = [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        ]
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                // Read existing settings
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var existingSettings = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove Quotio env keys
                if var env = existingSettings["env"] as? [String: String] {
                    for key in keysToRemove {
                        env.removeValue(forKey: key)
                    }
                    existingSettings["env"] = env.isEmpty ? nil : env
                }
                
                // Remove model if it was set by Quotio to a proxy model
                if let modelName = existingSettings["model"] as? String,
                   modelName.contains("gemini") || modelName.contains("gpt") {
                    existingSettings.removeValue(forKey: "model")
                }
                
                // Write updated settings
                let updatedData = try JSONSerialization.data(withJSONObject: existingSettings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed Quotio proxy configuration. Claude Code will now use its default Anthropic API endpoint.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update settings: \(error.localizedDescription)")
            }
        }
        
        // Manual mode - show what would be removed
        let instructions = """
        To revert to default, remove these environment variables from ~/.claude/settings.json:
        - ANTHROPIC_BASE_URL
        - ANTHROPIC_AUTH_TOKEN
        - ANTHROPIC_DEFAULT_OPUS_MODEL
        - ANTHROPIC_DEFAULT_SONNET_MODEL
        - ANTHROPIC_DEFAULT_HAIKU_MODEL
        """
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [RawConfigOutput(
                format: .json,
                content: "Remove the above keys from ~/.claude/settings.json env section",
                filename: "instructions.txt",
                targetPath: configPath,
                instructions: instructions
            )],
            instructions: instructions,
            modelsConfigured: 0
        )
    }
    
    private func generateCodexDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.codex/config.toml"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let content = try String(contentsOfFile: configPath, encoding: .utf8)
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try content.write(toFile: backupPath, atomically: true, encoding: .utf8)
                
                // Reuse the same TOML-aware filtering used by merge path,
                // including managed banner removal.
                let stubManagedConfig = buildManagedCodexTOML(model: "", proxyURL: "")
                let managedBanner = extractManagedCodexBanner(from: stubManagedConfig)
                let filteredLines = filterExistingCodexLines(existingContent: content, managedBanner: managedBanner)
                let newContent = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed CLIProxyAPI configuration. Codex CLI will now use OpenAI API directly.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove [model_providers.cliproxyapi] section from ~/.codex/config.toml",
            modelsConfigured: 0
        )
    }
    
    private func generateAmpDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.config/amp/settings.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: settingsPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
                var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(settingsPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: settingsPath, toPath: backupPath)
                
                // Remove amp.url
                settings.removeValue(forKey: "amp.url")
                
                let updatedData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: settingsPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: settingsPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed proxy URL. Amp CLI will now use its default endpoint.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update settings: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove 'amp.url' from ~/.config/amp/settings.json",
            modelsConfigured: 0
        )
    }
    
    private func generateOpenCodeDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.config/opencode/opencode.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove quotio provider
                if var providers = config["provider"] as? [String: Any] {
                    providers.removeValue(forKey: "quotio")
                    config["provider"] = providers.isEmpty ? nil : providers
                }
                
                let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed Quotio provider. OpenCode will use its default providers.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove 'provider.quotio' section from ~/.config/opencode/opencode.json",
            modelsConfigured: 0
        )
    }
    
    private func generateFactoryDroidDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.factory/config.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove custom_models that point to localhost
                if var customModels = config["custom_models"] as? [[String: Any]] {
                    customModels = customModels.filter { model in
                        guard let baseURL = model["base_url"] as? String else { return true }
                        return !baseURL.contains("127.0.0.1") && !baseURL.contains("localhost")
                    }
                    config["custom_models"] = customModels.isEmpty ? nil : customModels
                }
                
                let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed proxy models. Factory Droid will use its default configurations.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove custom_models with localhost base_url from ~/.factory/config.json",
            modelsConfigured: 0
        )
    }
    
    /// Generates Claude Code configuration with smart merge behavior
    ///
    /// **Merge Strategy:**
    /// - Reads existing settings.json if present
    /// - Preserves ALL user configuration: permissions, hooks, mcpServers, statusLine, plugins, etc.
    /// - Merges env object: keeps user's env keys (MCP_API_KEY, etc.), updates only Quotio's ANTHROPIC_* keys
    /// - Updates model field with current selection
    ///
    /// **Backup Behavior:**
    /// - Creates timestamped backup on each reconfigure: settings.json.backup.{unix_timestamp}
    /// - Each backup is unique and never overwritten
    /// - All previous backups are preserved
    private func generateClaudeCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, storageOption: ConfigStorageOption) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"

        let opusModel = config.modelSlots[.opus] ?? "gemini-claude-opus-4-5-thinking"
        let sonnetModel = config.modelSlots[.sonnet] ?? "gemini-claude-sonnet-4-5"
        let haikuModel = config.modelSlots[.haiku] ?? "gemini-3-flash-preview"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // Quotio-managed env keys (will be updated/added)
        let quotioEnvConfig: [String: String] = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": config.apiKey,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": opusModel,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnetModel,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": haikuModel
        ]

        let shellExports = """
        # CLIProxyAPI Configuration for Claude Code
        export ANTHROPIC_BASE_URL="\(baseURL)"
        export ANTHROPIC_AUTH_TOKEN="\(config.apiKey)"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="\(opusModel)"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="\(sonnetModel)"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="\(haikuModel)"
        """

        do {
            // Read existing settings.json to preserve user configuration
            // This preserves: permissions, hooks, mcpServers, statusLine, plugins, etc.
            var existingConfig: [String: Any] = [:]
            if fileManager.fileExists(atPath: configPath),
               let existingData = fileManager.contents(atPath: configPath),
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                existingConfig = parsed
            }

            // Merge env object: preserve user's existing env keys, update only Quotio-managed keys
            // User keys like MCP_API_KEY, DISABLE_INTERLEAVED_THINKING are preserved
            // Quotio keys (ANTHROPIC_*) are updated with new values
            var mergedEnv = existingConfig["env"] as? [String: String] ?? [:]
            for (key, value) in quotioEnvConfig {
                mergedEnv[key] = value
            }
            existingConfig["env"] = mergedEnv

            // Update model field (other top-level keys are automatically preserved)
            existingConfig["model"] = opusModel

            // Generate JSON from merged config
            let jsonData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            let shellProfilePath = ShellType.zsh.profilePath
            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "settings.json",
                    targetPath: configPath,
                    instructions: "Option 1: Save as ~/.claude/settings.json"
                ),
                RawConfigOutput(
                    format: .shellExport,
                    content: shellExports,
                    filename: nil,
                    targetPath: shellProfilePath,
                    instructions: "Option 2: Add to your shell profile"
                )
            ]
            
            if mode == .automatic {
                var backupPath: String? = nil
                let shouldWriteJson = storageOption == .jsonOnly || storageOption == .both
                
                if shouldWriteJson {
                    try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                    
                    if fileManager.fileExists(atPath: configPath) {
                        backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                        try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                    }
                    
                    try jsonData.write(to: URL(fileURLWithPath: configPath))
                }
                
                let instructions: String
                switch storageOption {
                case .jsonOnly:
                    instructions = "Configuration saved to ~/.claude/settings.json"
                case .shellOnly:
                    instructions = "Shell exports ready. Add to your shell profile to complete setup."
                case .both:
                    instructions = "Configuration saved to ~/.claude/settings.json and shell profile updated."
                }
                
                return .success(
                    type: .both,
                    mode: mode,
                    configPath: shouldWriteJson ? configPath : nil,
                    shellConfig: (storageOption == .shellOnly || storageOption == .both) ? shellExports : nil,
                    rawConfigs: rawConfigs,
                    instructions: instructions,
                    modelsConfigured: 3,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .both,
                    mode: mode,
                    configPath: configPath,
                    shellConfig: shellExports,
                    rawConfigs: rawConfigs,
                    instructions: "Choose one option: save settings.json OR add shell exports to your profile:",
                    modelsConfigured: 3
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }
    
    private func generateCodexConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let codexDir = "\(home)/.codex"
        let configPath = "\(codexDir)/config.toml"
        let authPath = "\(codexDir)/auth.json"

        let managedConfigTOML = buildManagedCodexTOML(
            model: config.modelSlots[.sonnet] ?? "gpt-5-codex",
            proxyURL: config.proxyURL,
            reasoningEffort: config.codexReasoningEffort
        )

        let configTOML: String
        if fileManager.fileExists(atPath: configPath) {
            do {
                let existingConfig = try String(contentsOfFile: configPath, encoding: .utf8)
                configTOML = mergeCodexConfig(existingContent: existingConfig, managedConfig: managedConfigTOML)
            } catch {
                Log.warning("Failed to read existing Codex config at \(configPath): \(error.localizedDescription). Falling back to managed-only config.")
                configTOML = managedConfigTOML + "\n"
            }
        } else {
            configTOML = managedConfigTOML + "\n"
        }
        
        let authJSON = """
        {
          "OPENAI_API_KEY": "\(config.apiKey)"
        }
        """
        
        let rawConfigs = [
            RawConfigOutput(
                format: .toml,
                content: configTOML,
                filename: "config.toml",
                targetPath: configPath,
                instructions: "Save this as ~/.codex/config.toml"
            ),
            RawConfigOutput(
                format: .json,
                content: authJSON,
                filename: "auth.json",
                targetPath: authPath,
                instructions: "Save this as ~/.codex/auth.json"
            )
        ]
        
        if mode == .automatic {
            try fileManager.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
            
            var backupPath: String? = nil
            if fileManager.fileExists(atPath: configPath) {
                backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
            }
            
            try configTOML.write(toFile: configPath, atomically: true, encoding: .utf8)
            try authJSON.write(toFile: authPath, atomically: true, encoding: .utf8)
            
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
            
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                authPath: authPath,
                rawConfigs: rawConfigs,
                instructions: "Configuration files created. Codex CLI is now configured to use CLIProxyAPI.",
                modelsConfigured: 1,
                backupPath: backupPath
            )
        } else {
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                authPath: authPath,
                rawConfigs: rawConfigs,
                instructions: "agents.codex.mergeAndSaveFiles".localizedStatic(),
                modelsConfigured: 1
            )
        }
    }
    
    private func generateAmpConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/amp"
        let dataDir = "\(home)/.local/share/amp"
        let settingsPath = "\(configDir)/settings.json"
        let secretsPath = "\(dataDir)/secrets.json"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        
        let settingsData = try Self.mergedAmpJSON(existing: nil, updates: ["amp.url": baseURL])
        let secretsData = try Self.mergedAmpJSON(existing: nil, updates: ["apiKey@\(baseURL)": config.apiKey])
        let settingsJSON = String(decoding: settingsData, as: UTF8.self)
        let secretsJSON = String(decoding: secretsData, as: UTF8.self)
        
        let envExports = """
        # Alternative: Environment variables for Amp CLI
        export AMP_URL="\(baseURL)"
        export AMP_API_KEY="\(config.apiKey)"
        """
        
        let rawConfigs = [
            RawConfigOutput(
                format: .json,
                content: settingsJSON,
                filename: "settings.json",
                targetPath: settingsPath,
                instructions: "agents.amp.mergeSettings".localizedStatic()
            ),
            RawConfigOutput(
                format: .json,
                content: secretsJSON,
                filename: "secrets.json",
                targetPath: secretsPath,
                instructions: "agents.amp.mergeSecrets".localizedStatic()
            ),
            RawConfigOutput(
                format: .shellExport,
                content: envExports,
                filename: nil,
                targetPath: "\(ShellType.zsh.profilePath) (alternative)",
                instructions: "agents.amp.useEnvironmentVariables".localizedStatic()
            )
        ]
        
        if mode == .automatic {
            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

            let existingSettings = fileManager.contents(atPath: settingsPath)
            let existingSecrets = fileManager.contents(atPath: secretsPath)
            let mergedSettings = try Self.mergedAmpJSON(
                existing: existingSettings,
                updates: ["amp.url": baseURL]
            )
            let mergedSecrets = try Self.mergedAmpJSON(
                existing: existingSecrets,
                updates: ["apiKey@\(baseURL)": config.apiKey]
            )
            let backupPath = try backupIfPresent(settingsPath)
            _ = try backupIfPresent(secretsPath)

            try mergedSettings.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            try mergedSecrets.write(to: URL(fileURLWithPath: secretsPath), options: .atomic)
            
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsPath)
            
            return .success(
                type: .both,
                mode: mode,
                configPath: settingsPath,
                authPath: secretsPath,
                shellConfig: envExports,
                rawConfigs: rawConfigs,
                instructions: "agents.amp.configSuccess".localizedStatic(),
                modelsConfigured: 1,
                backupPath: backupPath
            )
        } else {
            return .success(
                type: .both,
                mode: mode,
                configPath: settingsPath,
                authPath: secretsPath,
                shellConfig: envExports,
                rawConfigs: rawConfigs,
                instructions: "agents.amp.mergeAndSaveFiles".localizedStatic(),
                modelsConfigured: 1
            )
        }
    }

    nonisolated static func mergedAmpJSON(existing: Data?, updates: [String: String]) throws -> Data {
        var object: [String: Any] = [:]
        if let existing {
            guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            object = decoded
        }
        for (key, value) in updates {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func backupIfPresent(_ path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        var timestamp = Int(Date().timeIntervalSince1970)
        var backupPath = "\(path).backup.\(timestamp)"
        while fileManager.fileExists(atPath: backupPath) {
            timestamp += 1
            backupPath = "\(path).backup.\(timestamp)"
        }
        try fileManager.copyItem(atPath: path, toPath: backupPath)
        return backupPath
    }
    
    private func generateOpenCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/opencode"
        let configPath = "\(configDir)/opencode.json"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // Convert available models to OpenCode format dynamically
        var quotioModels: [String: [String: Any]] = [:]
        let modelsToUse = availableModels.isEmpty ? AvailableModel.allModels : availableModels

        for model in modelsToUse {
            quotioModels[model.name] = buildOpenCodeModelConfig(for: model.name)
        }

        let quotioProvider: [String: Any] = [
            "models": quotioModels,
            "name": "Quotio",
            "npm": "@ai-sdk/anthropic",
            "options": [
                "apiKey": config.apiKey,
                "baseURL": "\(baseURL)/v1",
                "litellmProxy": true
            ]
        ]

        do {
            var existingConfig: [String: Any] = [:]

            if fileManager.fileExists(atPath: configPath),
               let existingData = fileManager.contents(atPath: configPath),
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                existingConfig = parsed
            }

            if existingConfig["$schema"] == nil {
                existingConfig["$schema"] = "https://opencode.ai/config.json"
            }

            var providers = existingConfig["provider"] as? [String: Any] ?? [:]
            providers["quotio"] = quotioProvider
            existingConfig["provider"] = providers

            let jsonData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "opencode.json",
                    targetPath: configPath,
                    instructions: "Merge provider.quotio into ~/.config/opencode/opencode.json"
                )
            ]

            if mode == .automatic {
                try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                var backupPath: String? = nil
                if fileManager.fileExists(atPath: configPath) {
                    backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                    try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                }

                try jsonData.write(to: URL(fileURLWithPath: configPath))

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/\(modelsToUse.first?.name ?? "model")).",
                    modelsConfigured: quotioModels.count,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Merge provider.quotio section into your existing ~/.config/opencode/opencode.json:",
                    modelsConfigured: quotioModels.count
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }

    /// Build OpenCode model configuration based on model name patterns
    private func buildOpenCodeModelConfig(for modelName: String) -> [String: Any] {
        let displayName = modelName.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")

        var modelConfig: [String: Any] = ["name": displayName]

        // Determine limits and capabilities based on model family
        if modelName.contains("claude") {
            modelConfig["limit"] = ["context": 200000, "output": 64000]
            // Claude models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("gemini") {
            modelConfig["limit"] = ["context": 1048576, "output": 65536]
            // Gemini models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("gpt") {
            modelConfig["limit"] = ["context": 400000, "output": 32768]
            // GPT-4+ models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("qwen") && modelName.contains("vl") {
            // Qwen VL (vision-language) models
            modelConfig["limit"] = ["context": 128000, "output": 16384]
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.lowercased().contains("minimax") {
            // MiniMax multimodal models: 1M context with text, image, and video input
            modelConfig["limit"] = ["context": 1000000, "output": 16384]
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image", "video"], "output": ["text"]]
        } else {
            // Default: text-only models
            modelConfig["limit"] = ["context": 128000, "output": 16384]
            modelConfig["attachment"] = false
            modelConfig["modalities"] = ["input": ["text"], "output": ["text"]]
        }

        // Add reasoning options for thinking/reasoning models
        if modelName.contains("thinking") {
            modelConfig["reasoning"] = true
            modelConfig["options"] = ["thinking": ["type": "enabled", "budgetTokens": 10000]]
        } else if modelName.contains("codex") || modelName.hasPrefix("gpt-5") || modelName.hasPrefix("o1") || modelName.hasPrefix("o3") {
            modelConfig["reasoning"] = true
            if modelName.contains("max") {
                modelConfig["options"] = ["reasoning": ["effort": "high"]]
            } else if modelName.contains("mini") {
                modelConfig["options"] = ["reasoning": ["effort": "low"]]
            } else {
                modelConfig["options"] = ["reasoning": ["effort": "medium"]]
            }
        }

        return modelConfig
    }
    
    private func generateFactoryDroidConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.factory"
        let configPath = "\(configDir)/config.json"

        let openaiBaseURL = "\(config.proxyURL.replacingOccurrences(of: "/v1", with: ""))/v1"

        // Convert available models to Factory Droid format dynamically
        let modelsToUse = availableModels.isEmpty ? AvailableModel.allModels : availableModels
        let customModels: [[String: Any]] = modelsToUse.map { model in
            [
                "model": model.name,
                "model_display_name": model.name,
                "base_url": openaiBaseURL,
                "api_key": config.apiKey,
                "provider": "openai"
            ]
        }

        let factoryConfig: [String: Any] = ["custom_models": customModels]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: factoryConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "config.json",
                    targetPath: configPath,
                    instructions: "Save this as ~/.factory/config.json"
                )
            ]

            if mode == .automatic {
                try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                var backupPath: String? = nil
                if fileManager.fileExists(atPath: configPath) {
                    backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                    try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                }

                try jsonData.write(to: URL(fileURLWithPath: configPath))

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Configuration saved. Run 'droid' or 'factory' to start using Factory Droid.",
                    modelsConfigured: customModels.count,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Copy the configuration below and save it as ~/.factory/config.json:",
                    modelsConfigured: customModels.count
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }
    
    func fetchAvailableModels(config: AgentConfiguration) async throws -> [AvailableModel] {
        guard let url = URL(string: "\(config.proxyURL)/models") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let proxyConfig = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
        let session = URLSession(configuration: proxyConfig)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Parse struct matching OpenAI /v1/models response
        struct ModelsResponse: Decodable {
            struct ModelItem: Decodable {
                let id: String
                let owned_by: String?
            }
            let data: [ModelItem]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)

        // Fetch available Copilot models to filter out unavailable ones
        let copilotFetcher = CopilotQuotaFetcher()
        let availableCopilotModelIds = await copilotFetcher.fetchUserAvailableModelIds()

        return decoded.data.compactMap { item in
            let provider = item.owned_by ?? "openai"

            // Filter GitHub Copilot models - only include those actually available to the user
            if provider == "github-copilot" {
                // If we have Copilot accounts, filter by available models
                if !availableCopilotModelIds.isEmpty {
                    guard availableCopilotModelIds.contains(item.id) else {
                        return nil
                    }
                }
                // If no Copilot accounts, still show the model (user might add account later)
            }

            return AvailableModel(
                id: item.id,
                name: item.id,
                provider: provider,
                isDefault: false
            )
        }
    }
    
    func testConnection(agent: CLIAgent, config: AgentConfiguration) async -> ConnectionTestResult {
        let startTime = Date()
        
        guard let url = URL(string: "\(config.proxyURL)/models") else {
            return ConnectionTestResult(
                success: false,
                message: "Invalid proxy URL",
                latencyMs: nil,
                modelResponded: nil
            )
        }
        
        var request = URLRequest(url: url)
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            let proxyConfig = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
            let session = URLSession(configuration: proxyConfig)
            let (data, response) = try await session.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                return ConnectionTestResult(
                    success: false,
                    message: "Invalid response",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   let firstModel = models.first?["id"] as? String {
                    return ConnectionTestResult(
                        success: true,
                        message: "Connected successfully",
                        latencyMs: latencyMs,
                        modelResponded: firstModel
                    )
                }
                return ConnectionTestResult(
                    success: true,
                    message: "Connected successfully",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            } else {
                var errorMessage = "HTTP \(httpResponse.statusCode)"
                
                // Try to parse detailed error message from proxy response (OpenAI format)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any],
                   let detailedMessage = errorObj["message"] as? String {
                    errorMessage = detailedMessage
                }
                
                return ConnectionTestResult(
                    success: false,
                    message: errorMessage,
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
        } catch {
            return ConnectionTestResult(
                success: false,
                message: error.localizedDescription,
                latencyMs: nil,
                modelResponded: nil
            )
        }
    }
}
