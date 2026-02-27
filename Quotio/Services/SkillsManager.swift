//
//  SkillsManager.swift
//  Quotio - Skills Management Service
//

import Foundation

actor SkillsManager {
    static let shared = SkillsManager()
    
    private var skills: [Skill] = []
    private let fileManager = FileManager.default
    
    private init() {}
    
    // MARK: - Skills Directory
    
    private var skillsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Quotio/skills")
    }
    
    // MARK: - Load Skills
    
    func loadSkills() async {
        // Ensure directory exists
        try? fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        
        var loadedSkills: [Skill] = []
        
        guard let files = try? fileManager.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil) else {
            print("[Skills] Failed to read skills directory")
            skills = []
            return
        }
        
        print("[Skills] Found \(files.count) files in skills directory")
        
        for file in files where file.pathExtension == "yaml" || file.pathExtension == "yml" {
            print("[Skills] Loading: \(file.lastPathComponent)")
            if let skill = try? await loadSkill(from: file) {
                loadedSkills.append(skill)
                print("[Skills] ✓ Loaded: \(skill.name)")
            } else {
                print("[Skills] ✗ Failed to load: \(file.lastPathComponent)")
            }
        }
        
        skills = loadedSkills
        print("[Skills] Total loaded: \(skills.count) skills")
    }
    
    private func loadSkill(from url: URL) async throws -> Skill {
        let data = try Data(contentsOf: url)
        let decoder = YAMLDecoder()
        return try decoder.decode(Skill.self, from: data)
    }
    
    // MARK: - Match Skills
    
    func findMatchingSkills(prompt: String, filePath: String?, agent: String?) -> [Skill] {
        print("[Skills] Finding matches for prompt: '\(prompt.prefix(50))...', agent: \(agent ?? "none")")
        let matched = skills.filter { skill in
            let matches = skill.enabled && skill.triggers.matches(text: prompt, filePath: filePath, agent: agent)
            if matches {
                print("[Skills] ✓ Matched: \(skill.name)")
            }
            return matches
        }
        print("[Skills] Total matches: \(matched.count)")
        return matched
    }
    
    // MARK: - Usage Tracking
    
    func recordUsage(skillId: UUID, agent: String?) async {
        guard let index = skills.firstIndex(where: { $0.id == skillId }) else { return }
        
        var skill = skills[index]
        skill.usageCount += 1
        skill.lastUsed = Date()
        skill.lastAgent = agent
        skills[index] = skill
        
        // Save to disk
        try? await saveSkill(skill)
    }
    
    // MARK: - Agent Detection
    
    func detectAgent(from headers: [String: String]) -> String? {
        // Check User-Agent header
        if let userAgent = headers["User-Agent"] ?? headers["user-agent"] {
            if userAgent.contains("claude") { return "Claude Code" }
            if userAgent.contains("antigravity") { return "Antigravity" }
            if userAgent.contains("opencode") { return "OpenCode" }
            if userAgent.contains("gemini") { return "Gemini CLI" }
            if userAgent.contains("codex") { return "Codex CLI" }
            if userAgent.contains("amp") { return "Amp CLI" }
        }
        
        // Check custom headers
        if let clientName = headers["X-Client-Name"] ?? headers["x-client-name"] {
            return clientName
        }
        
        return nil
    }
    
    // MARK: - Enrich Request
    
    func enrichRequest(body: String, skills: [Skill], mcpContext: [String: String]) -> String {
        guard !skills.isEmpty else { return body }
        
        guard let bodyData = body.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return body
        }
        
        // Build enriched prompt
        var enrichedPrompt = ""
        
        // Add Skill instructions
        for skill in skills {
            enrichedPrompt += "# \(skill.name)\n\(skill.instructions)\n\n"
        }
        
        // Add MCP context if available
        if !mcpContext.isEmpty {
            enrichedPrompt += "# Context\n"
            for (key, value) in mcpContext {
                enrichedPrompt += "- \(key): \(value)\n"
            }
            enrichedPrompt += "\n"
        }
        
        // Append original prompt
        if let messages = json["messages"] as? [[String: Any]],
           let lastMessage = messages.last,
           let content = lastMessage["content"] as? String {
            enrichedPrompt += content
            
            // Update last message
            var updatedMessages = messages
            var updatedLastMessage = lastMessage
            updatedLastMessage["content"] = enrichedPrompt
            updatedMessages[updatedMessages.count - 1] = updatedLastMessage
            json["messages"] = updatedMessages
        } else if let prompt = json["prompt"] as? String {
            enrichedPrompt += prompt
            json["prompt"] = enrichedPrompt
        }
        
        // Convert back to JSON
        guard let updatedData = try? JSONSerialization.data(withJSONObject: json),
              let updatedBody = String(data: updatedData, encoding: .utf8) else {
            return body
        }
        
        return updatedBody
    }
    
    // MARK: - CRUD Operations
    
    func getSkills() -> [Skill] {
        skills
    }
    
    func saveSkill(_ skill: Skill) async throws {
        let filename = skill.name.lowercased().replacingOccurrences(of: " ", with: "-") + ".yaml"
        let url = skillsDirectory.appendingPathComponent(filename)
        
        let encoder = YAMLEncoder()
        let data = try encoder.encode(skill)
        try data.write(to: url)
        
        // Sync to all agent directories
        await syncSkillToAgents(skill, filename: filename, data: data)
        
        await loadSkills()
    }
    
    private func syncSkillToAgents(_ skill: Skill, filename: String, data: Data) async {
        for agent in CLIAgent.allCases {
            let agentSkillsDir = NSString(string: agent.skillsDirectory).expandingTildeInPath
            let agentSkillsURL = URL(fileURLWithPath: agentSkillsDir)
            
            // Create skill directory (e.g., ~/.claude/skills/code-review/)
            let skillName = skill.name.lowercased().replacingOccurrences(of: " ", with: "-")
            let skillDir = agentSkillsURL.appendingPathComponent(skillName)
            try? fileManager.createDirectory(at: skillDir, withIntermediateDirectories: true)
            
            // All agents use SKILL.md format (Agent Skills open standard)
            let skillMD = """
            ---
            name: \(skillName)
            description: \(skill.description). Triggers: \(skill.triggers.keywords.joined(separator: ", "))
            version: 1.0.0
            ---
            
            # \(skill.name)
            
            \(skill.instructions)
            
            ## When to Use
            
            This skill activates when:
            \(skill.triggers.keywords.map { "- User mentions '\($0)'" }.joined(separator: "\n"))
            
            ## File Patterns
            
            \(skill.triggers.files.isEmpty ? "Applies to all files" : skill.triggers.files.map { "- `\($0)`" }.joined(separator: "\n"))
            
            ## Tools Available
            
            \(skill.tools.isEmpty ? "No specific tools required" : skill.tools.map { "- \($0)" }.joined(separator: "\n"))
            """
            
            let skillFile = skillDir.appendingPathComponent("SKILL.md")
            try? skillMD.data(using: .utf8)?.write(to: skillFile)
            
            print("[Skills] Synced '\(skill.name)' to \(agent.displayName)")
        }
    }
    
    func deleteSkill(_ skill: Skill) async throws {
        let filename = skill.name.lowercased().replacingOccurrences(of: " ", with: "-") + ".yaml"
        let url = skillsDirectory.appendingPathComponent(filename)
        try fileManager.removeItem(at: url)
        
        // Delete from all agent directories (all use SKILL.md format)
        let skillName = skill.name.lowercased().replacingOccurrences(of: " ", with: "-")
        for agent in CLIAgent.allCases {
            let agentSkillsDir = NSString(string: agent.skillsDirectory).expandingTildeInPath
            let skillDir = URL(fileURLWithPath: agentSkillsDir).appendingPathComponent(skillName)
            try? fileManager.removeItem(at: skillDir)
            print("[Skills] Deleted '\(skill.name)' from \(agent.displayName)")
        }
        
        await loadSkills()
    }
}

// MARK: - YAML Coding (Minimal Implementation)

private struct YAMLDecoder {
    nonisolated func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Simple YAML parser for Skill format
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8"))
        }
        
        var name = ""
        var description = ""
        var keywords: [String] = []
        var files: [String] = []
        var agents: [String] = []
        var instructions = ""
        var tools: [String] = []
        var enabled = true
        var usageCount = 0
        var lastUsed: Date?
        var lastAgent: String?
        
        var currentSection = ""
        var instructionsLines: [String] = []
        
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("name:") {
                name = trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("description:") {
                description = trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("enabled:") {
                enabled = trimmed.replacingOccurrences(of: "enabled:", with: "").trimmingCharacters(in: .whitespaces) == "true"
            } else if trimmed.hasPrefix("usageCount:") {
                usageCount = Int(trimmed.replacingOccurrences(of: "usageCount:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("lastUsed:") {
                let dateStr = trimmed.replacingOccurrences(of: "lastUsed:", with: "").trimmingCharacters(in: .whitespaces)
                if !dateStr.isEmpty, let date = try? Date(dateStr, strategy: .iso8601) {
                    lastUsed = date
                }
            } else if trimmed.hasPrefix("lastAgent:") {
                let agent = trimmed.replacingOccurrences(of: "lastAgent:", with: "").trimmingCharacters(in: .whitespaces)
                lastAgent = agent.isEmpty ? nil : agent
            } else if trimmed == "triggers:" {
                currentSection = "triggers"
            } else if trimmed == "instructions: |" {
                currentSection = "instructions"
            } else if trimmed == "tools:" {
                currentSection = "tools"
            } else if currentSection == "triggers" {
                if trimmed.hasPrefix("keywords:") {
                    let keywordsStr = trimmed.replacingOccurrences(of: "keywords:", with: "").trimmingCharacters(in: .whitespaces)
                    keywords = parseArray(keywordsStr)
                } else if trimmed.hasPrefix("files:") {
                    let filesStr = trimmed.replacingOccurrences(of: "files:", with: "").trimmingCharacters(in: .whitespaces)
                    files = parseArray(filesStr)
                } else if trimmed.hasPrefix("agents:") {
                    let agentsStr = trimmed.replacingOccurrences(of: "agents:", with: "").trimmingCharacters(in: .whitespaces)
                    agents = parseArray(agentsStr)
                }
            } else if currentSection == "instructions" && !trimmed.isEmpty {
                instructionsLines.append(line.trimmingCharacters(in: .whitespaces))
            } else if currentSection == "tools" && trimmed.hasPrefix("-") {
                let tool = trimmed.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
                tools.append(tool)
            }
        }
        
        instructions = instructionsLines.joined(separator: "\n")
        
        let skill = Skill(
            name: name,
            description: description,
            triggers: SkillTriggers(keywords: keywords, files: files, agents: agents),
            instructions: instructions,
            tools: tools,
            enabled: enabled,
            usageCount: usageCount,
            lastUsed: lastUsed,
            lastAgent: lastAgent
        )
        
        return skill as! T
    }
    
    private nonisolated func parseArray(_ str: String) -> [String] {
        let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return cleaned.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct YAMLEncoder {
    nonisolated func encode<T: Encodable>(_ value: T) throws -> Data {
        guard let skill = value as? Skill else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Not a Skill"))
        }
        
        let yaml = """
        name: \(skill.name)
        description: \(skill.description)
        enabled: \(skill.enabled)
        usageCount: \(skill.usageCount)
        lastUsed: \(skill.lastUsed?.ISO8601Format() ?? "")
        lastAgent: \(skill.lastAgent ?? "")
        triggers:
          keywords: [\(skill.triggers.keywords.joined(separator: ", "))]
          files: [\(skill.triggers.files.joined(separator: ", "))]
          agents: [\(skill.triggers.agents.joined(separator: ", "))]
        instructions: |
        \(skill.instructions.components(separatedBy: .newlines).map { "  " + $0 }.joined(separator: "\n"))
        tools:
        \(skill.tools.map { "  - " + $0 }.joined(separator: "\n"))
        """
        
        return yaml.data(using: .utf8)!
    }
}
