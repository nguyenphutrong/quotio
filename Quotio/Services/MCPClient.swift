//
//  MCPClient.swift
//  Quotio - Model Context Protocol Client
//

import Foundation

actor MCPClient {
    static let shared = MCPClient()
    
    private var servers: [MCPServer] = []
    private let fileManager = FileManager.default
    
    private init() {}
    
    // MARK: - Configuration
    
    private var configPath: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Quotio/quotio.yaml")
    }

    /// MCP sync currently writes JSON config payloads; skip agents that do not use JSON-backed MCP settings.
    private func mcpSyncPath(for agent: CLIAgent) -> String? {
        switch agent {
        case .claudeCode, .ampCLI, .openCode, .factoryDroid:
            return agent.configPaths.first
        case .codexCLI, .geminiCLI:
            return nil
        }
    }
    
    func loadConfig() async {
        guard fileManager.fileExists(atPath: configPath.path),
              let data = try? Data(contentsOf: configPath),
              let yaml = String(data: data, encoding: .utf8) else {
            servers = []
            return
        }
        
        // Simple YAML parser for MCP config
        var loadedServers: [MCPServer] = []
        var inServersSection = false
        var currentName = ""
        var currentURL = ""
        
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed == "servers:" {
                inServersSection = true
            } else if inServersSection {
                if trimmed.hasPrefix("- name:") {
                    if !currentName.isEmpty && !currentURL.isEmpty {
                        loadedServers.append(MCPServer(name: currentName, url: currentURL))
                    }
                    currentName = trimmed.replacingOccurrences(of: "- name:", with: "").trimmingCharacters(in: .whitespaces)
                    currentURL = ""
                } else if trimmed.hasPrefix("url:") {
                    currentURL = trimmed.replacingOccurrences(of: "url:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        if !currentName.isEmpty && !currentURL.isEmpty {
            loadedServers.append(MCPServer(name: currentName, url: currentURL))
        }
        
        servers = loadedServers
    }
    
    func saveConfig() async throws {
        // Build MCP JSON config (standard format)
        let mcpConfig: [String: Any] = [
            "mcpServers": servers.reduce(into: [String: [String: Any]]()) { result, server in
                result[server.name] = [
                    "command": server.type == .stdio ? server.url.replacingOccurrences(of: "stdio://", with: "") : "node",
                    "args": server.type == .http ? [server.url] : [] as [String],
                    "env": [:] as [String: String]
                ]
            }
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: mcpConfig, options: [.prettyPrinted])
        
        // Save to Quotio's config
        try jsonData.write(to: configPath)
        
        // Sync to all agent MCP configs
        for agent in CLIAgent.allCases {
            guard let mcpPath = mcpSyncPath(for: agent) else {
                continue
            }

            let agentMCPPath = NSString(string: mcpPath).expandingTildeInPath
            let agentMCPURL = URL(fileURLWithPath: agentMCPPath)
            
            // Create parent directory if needed
            try? FileManager.default.createDirectory(at: agentMCPURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            // Write MCP config
            try? jsonData.write(to: agentMCPURL)
            print("[MCP] Synced config to \(agent.displayName)")
        }
    }
    
    // MARK: - Fetch Context
    
    func fetchContext(for skills: [Skill]) async -> [String: String] {
        var context: [String: String] = [:]
        
        // Collect required tools from Skills
        let requiredTools = Set(skills.flatMap { $0.tools })
        
        for tool in requiredTools {
            if let server = servers.first(where: { $0.name == tool }) {
                if let toolContext = await fetchFromServer(server) {
                    context[tool] = toolContext
                }
            }
        }
        
        return context
    }
    
    private func fetchFromServer(_ server: MCPServer) async -> String? {
        // Context injection - fetch tool information and format as text
        switch server.type {
        case .stdio:
            return await fetchStdioContext(server)
        case .http:
            return await fetchHTTPContext(server)
        }
    }
    
    private func fetchStdioContext(_ server: MCPServer) async -> String? {
        // For stdio servers, return available tool descriptions
        let toolDescriptions: [String: String] = [
            "filesystem": "Access to read/write files in the workspace",
            "git": "Git repository operations (status, diff, commit)",
            "terminal": "Execute shell commands",
            "browser": "Web browsing and search capabilities"
        ]
        
        if let description = toolDescriptions[server.name] {
            return "[MCP Tool: \(server.name)] \(description)"
        }
        
        return "[MCP Tool: \(server.name)] Available"
    }
    
    private func fetchHTTPContext(_ server: MCPServer) async -> String? {
        guard let url = URL(string: server.url) else { return nil }
        
        // Try to fetch tool schema from HTTP endpoint
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // JSON-RPC 2.0 request for tool list
            let rpcRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "tools/list",
                "id": 1
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: rpcRequest)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let tools = result["tools"] as? [[String: Any]] {
                
                let toolNames = tools.compactMap { $0["name"] as? String }.joined(separator: ", ")
                return "[MCP Server: \(server.name)] Tools: \(toolNames)"
            }
        } catch {
            return nil
        }
        
        return nil
    }
    
    // MARK: - CRUD
    
    func getServers() -> [MCPServer] {
        servers
    }
    
    func addServer(_ server: MCPServer) async throws {
        servers.append(server)
        try await saveConfig()
    }
    
    func removeServer(_ server: MCPServer) async throws {
        servers.removeAll { $0.id == server.id }
        try await saveConfig()
    }
    
    // MARK: - MCP Registry API
    
    func fetchFromRegistry(search: String? = nil, limit: Int = 20) async throws -> [MCPServer] {
        var urlString = "https://registry.modelcontextprotocol.io/v0/servers?limit=\(limit)"
        if let search = search {
            urlString += "&search=\(search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        print("[MCP Registry] Fetching: \(urlString)")
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Decode on a background task to avoid main actor isolation
        let response = try await Task.detached {
            try JSONDecoder().decode(MCPRegistryResponse.self, from: data)
        }.value
        
        print("[MCP Registry] Found \(response.servers.count) servers")
        
        return response.servers.compactMap { entry in
            // Try packages first, then remotes
            if let package = entry.server.packages?.first {
                let url = package.transport.type == .stdio 
                    ? "stdio://\(package.identifier)"
                    : package.transport.url ?? ""
                
                return MCPServer(
                    name: entry.server.name.components(separatedBy: "/").last ?? entry.server.name,
                    url: url
                )
            } else if let remote = entry.server.remotes?.first {
                return MCPServer(
                    name: entry.server.name.components(separatedBy: "/").last ?? entry.server.name,
                    url: remote.url
                )
            }
            
            print("[MCP Registry] Skipping server with no packages or remotes: \(entry.server.name)")
            return nil
        }
    }
}

// MARK: - Registry Response Models

private struct MCPRegistryResponse: Sendable {
    let servers: [MCPRegistryEntry]
}

extension MCPRegistryResponse: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.servers = try container.decode([MCPRegistryEntry].self, forKey: .servers)
    }
}

private struct MCPRegistryEntry: Sendable {
    let server: MCPRegistryServer
}

extension MCPRegistryEntry: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.server = try container.decode(MCPRegistryServer.self, forKey: .server)
    }
}

private struct MCPRegistryServer: Sendable {
    let name: String
    let description: String
    let packages: [MCPPackage]?
    let remotes: [MCPRemote]?
}

extension MCPRegistryServer: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.packages = try container.decodeIfPresent([MCPPackage].self, forKey: .packages)
        self.remotes = try container.decodeIfPresent([MCPRemote].self, forKey: .remotes)
    }
}

private struct MCPRemote: Sendable {
    let type: String
    let url: String
}

extension MCPRemote: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.url = try container.decode(String.self, forKey: .url)
    }
}

private struct MCPPackage: Sendable {
    let identifier: String
    let transport: MCPTransport
}

extension MCPPackage: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identifier = try container.decode(String.self, forKey: .identifier)
        self.transport = try container.decode(MCPTransport.self, forKey: .transport)
    }
}

private struct MCPTransport: Sendable {
    let type: MCPTransportType
    let url: String?
    
    enum MCPTransportType: String, Codable, Sendable {
        case stdio
        case sse
        case streamableHttp = "streamable-http"
    }
}

extension MCPTransport: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(MCPTransportType.self, forKey: .type)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
    }
}
