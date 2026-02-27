//
//  SkillModels.swift
//  Quotio
//

import Foundation

// MARK: - Skill Definition

struct Skill: Identifiable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let triggers: SkillTriggers
    let instructions: String
    let tools: [String]
    let enabled: Bool
    var usageCount: Int
    var lastUsed: Date?
    var lastAgent: String?
    
    nonisolated init(id: UUID = UUID(), name: String, description: String, triggers: SkillTriggers, instructions: String, tools: [String] = [], enabled: Bool = true, usageCount: Int = 0, lastUsed: Date? = nil, lastAgent: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.triggers = triggers
        self.instructions = instructions
        self.tools = tools
        self.enabled = enabled
        self.usageCount = usageCount
        self.lastUsed = lastUsed
        self.lastAgent = lastAgent
    }
}

// Manual Codable conformance to avoid MainActor isolation
extension Skill: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, description, triggers, instructions, tools, enabled, usageCount, lastUsed, lastAgent
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.triggers = try container.decode(SkillTriggers.self, forKey: .triggers)
        self.instructions = try container.decode(String.self, forKey: .instructions)
        self.tools = try container.decode([String].self, forKey: .tools)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.usageCount = try container.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        self.lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        self.lastAgent = try container.decodeIfPresent(String.self, forKey: .lastAgent)
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(triggers, forKey: .triggers)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(tools, forKey: .tools)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(usageCount, forKey: .usageCount)
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try container.encodeIfPresent(lastAgent, forKey: .lastAgent)
    }
}

struct SkillTriggers: Codable, Sendable {
    let keywords: [String]
    let files: [String]
    let agents: [String] // e.g., ["claude", "antigravity", "opencode"]
    
    nonisolated init(keywords: [String] = [], files: [String] = [], agents: [String] = []) {
        self.keywords = keywords
        self.files = files
        self.agents = agents
    }
    
    nonisolated func matches(text: String, filePath: String?, agent: String? = nil) -> Bool {
        let keywordMatch = keywords.isEmpty || keywords.contains { text.localizedCaseInsensitiveContains($0) }
        let fileMatch = files.isEmpty || (filePath.map { path in files.contains { pattern in matchesGlob(path: path, pattern: pattern) } } ?? false)
        let agentMatch = agents.isEmpty || (agent.map { agentName in agents.contains { agentName.localizedCaseInsensitiveContains($0) } } ?? true)
        return keywordMatch && fileMatch && agentMatch
    }
    
    private nonisolated func matchesGlob(path: String, pattern: String) -> Bool {
        let regex = pattern.replacingOccurrences(of: "*", with: ".*").replacingOccurrences(of: "?", with: ".")
        return path.range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - MCP Configuration

struct MCPConfig: Codable, Sendable {
    let servers: [MCPServer]
}

struct MCPServer: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: String
    let type: MCPServerType
    
    nonisolated init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
        self.type = url.hasPrefix("stdio://") ? .stdio : .http
    }
    
    enum MCPServerType: String, Codable, Sendable {
        case stdio
        case http
    }
}

// MARK: - Skill Request

struct SkillRequest: Sendable {
    let userPrompt: String
    let skills: [Skill]
    let filePath: String?
    let mcpContext: [String: String]
    
    var composedPrompt: String {
        var prompt = ""
        for skill in skills {
            prompt += "# \(skill.name)\n\(skill.instructions)\n\n"
        }
        prompt += userPrompt
        return prompt
    }
}
