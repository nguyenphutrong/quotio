//
//  SkillsScreen.swift
//  Quotio - Skills Management UI
//

import SwiftUI

struct SkillsScreen: View {
    @State private var skills: [Skill] = []
    @State private var mcpServers: [MCPServer] = []
    @State private var isLoading = false
    @State private var showAddSkill = false
    @State private var showAddServer = false
    @State private var showBrowseRegistry = false
    @State private var selectedSkill: Skill?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if skills.isEmpty {
                    emptyState
                } else {
                    skillsList
                }
                
                Divider()
                    .padding(.vertical)
                
                mcpServersSection
            }
            .padding()
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSkill = true
                } label: {
                    Label("Add Skill", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSkill) {
            SkillEditorSheet(skill: nil) {
                Task { await loadData() }
            }
        }
        .sheet(item: $selectedSkill) { skill in
            SkillEditorSheet(skill: skill) {
                Task { await loadData() }
            }
        }
        .sheet(isPresented: $showAddServer) {
            MCPServerSheet { await loadData() }
        }
        .sheet(isPresented: $showBrowseRegistry) {
            MCPRegistryBrowser { await loadData() }
        }
        .task {
            await loadData()
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("No Skills Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Create Skills to add reusable instructions\nthat work across all AI agents")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button {
                showAddSkill = true
            } label: {
                Label("Create First Skill", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skills")
                .font(.headline)
            
            ForEach(skills) { skill in
                SkillCard(skill: skill) {
                    selectedSkill = skill
                } onToggle: {
                    Task { await toggleSkill(skill) }
                } onDelete: {
                    Task { await deleteSkill(skill) }
                }
            }
        }
    }
    
    private var mcpServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP Servers")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    showBrowseRegistry = true
                } label: {
                    Label("Browse Registry", systemImage: "globe")
                        .font(.caption)
                }
                
                Button {
                    showAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus.circle")
                        .font(.caption)
                }
            }
            
            if mcpServers.isEmpty {
                Text("No MCP servers configured")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(mcpServers) { server in
                    MCPServerRow(server: server) {
                        Task { await deleteServer(server) }
                    }
                }
            }
        }
    }
    
    private func loadData() async {
        isLoading = true
        skills = await SkillsManager.shared.getSkills()
        mcpServers = await MCPClient.shared.getServers()
        isLoading = false
    }
    
    private func toggleSkill(_ skill: Skill) async {
        var updated = skill
        updated = Skill(
            id: skill.id,
            name: skill.name,
            description: skill.description,
            triggers: skill.triggers,
            instructions: skill.instructions,
            tools: skill.tools,
            enabled: !skill.enabled,
            usageCount: skill.usageCount,
            lastUsed: skill.lastUsed,
            lastAgent: skill.lastAgent
        )
        try? await SkillsManager.shared.saveSkill(updated)
        await loadData()
    }
    
    private func deleteSkill(_ skill: Skill) async {
        try? await SkillsManager.shared.deleteSkill(skill)
        await loadData()
    }
    
    private func deleteServer(_ server: MCPServer) async {
        try? await MCPClient.shared.removeServer(server)
        await loadData()
    }
}

// MARK: - Skill Card

struct SkillCard: View {
    let skill: Skill
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: skill.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(skill.enabled ? .green : .secondary)
                
                Text(skill.name)
                    .font(.headline)
                
                Spacer()
                
                // Usage badge
                if skill.usageCount > 0 {
                    Text("\(skill.usageCount) uses")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.2))
                        .cornerRadius(4)
                }
                
                Menu {
                    Button("Edit", action: onEdit)
                    Button("Toggle", action: onToggle)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            
            Text(skill.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // Last used info
            if let lastUsed = skill.lastUsed, let lastAgent = skill.lastAgent {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Last used by \(lastAgent)")
                        .font(.caption2)
                    Text("•")
                        .font(.caption2)
                    Text(lastUsed, style: .relative)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            
            if !skill.triggers.keywords.isEmpty {
                HStack {
                    Text("Keywords:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(skill.triggers.keywords.joined(separator: ", "))
                        .font(.caption2)
                }
            }
            
            if !skill.triggers.agents.isEmpty {
                HStack {
                    Text("Agents:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(skill.triggers.agents.joined(separator: ", "))
                        .font(.caption2)
                }
            }
            
            if !skill.tools.isEmpty {
                HStack {
                    Text("Tools:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(skill.tools.joined(separator: ", "))
                        .font(.caption2)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(8)
    }
}

// MARK: - MCP Server Row

struct MCPServerRow: View {
    let server: MCPServer
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: server.type == .stdio ? "terminal" : "network")
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading) {
                Text(server.name)
                    .font(.subheadline)
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Skill Editor Sheet

struct SkillEditorSheet: View {
    let skill: Skill?
    let onSave: () -> Void
    
    @State private var name = ""
    @State private var description = ""
    @State private var keywords = ""
    @State private var files = ""
    @State private var agents = ""
    @State private var instructions = ""
    @State private var tools = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)
                }
                
                Section("Triggers") {
                    TextField("Keywords (comma-separated)", text: $keywords)
                        .help("e.g., review, audit, check")
                    TextField("File patterns (comma-separated)", text: $files)
                        .help("e.g., *.swift, *.ts, *.py")
                    TextField("Agents (comma-separated)", text: $agents)
                        .help("e.g., claude, antigravity, opencode")
                }
                
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 150)
                }
                
                Section("MCP Tools") {
                    TextField("Tool names (comma-separated)", text: $tools)
                        .help("e.g., filesystem, git, terminal")
                }
            }
            .navigationTitle(skill == nil ? "New Skill" : "Edit Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear {
                if let skill = skill {
                    name = skill.name
                    description = skill.description
                    keywords = skill.triggers.keywords.joined(separator: ", ")
                    files = skill.triggers.files.joined(separator: ", ")
                    agents = skill.triggers.agents.joined(separator: ", ")
                    instructions = skill.instructions
                    tools = skill.tools.joined(separator: ", ")
                }
            }
        }
    }
    
    private func save() async {
        let newSkill = Skill(
            id: skill?.id ?? UUID(),
            name: name,
            description: description,
            triggers: SkillTriggers(
                keywords: keywords.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                files: files.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                agents: agents.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            ),
            instructions: instructions,
            tools: tools.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            enabled: skill?.enabled ?? true,
            usageCount: skill?.usageCount ?? 0,
            lastUsed: skill?.lastUsed,
            lastAgent: skill?.lastAgent
        )
        
        try? await SkillsManager.shared.saveSkill(newSkill)
        onSave()
    }
}

// MARK: - MCP Server Sheet

struct MCPServerSheet: View {
    let onSave: () async -> Void
    
    @State private var name = ""
    @State private var url = ""
    @State private var serverType: MCPServer.MCPServerType = .http
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                
                Picker("Type", selection: $serverType) {
                    Text("HTTP").tag(MCPServer.MCPServerType.http)
                    Text("Stdio").tag(MCPServer.MCPServerType.stdio)
                }
                
                TextField("URL", text: $url)
            }
            .navigationTitle("Add MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
    
    private func save() async {
        let server = MCPServer(name: name, url: url)
        try? await MCPClient.shared.addServer(server)
        await onSave()
    }
}


// MARK: - MCP Registry Browser

struct MCPRegistryBrowser: View {
    let onSave: () async -> Void
    
    @State private var searchText = ""
    @State private var servers: [MCPServer] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                        Text("Error")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await search(searchText) }
                        }
                    }
                    .padding()
                } else if isLoading {
                    ProgressView("Searching registry...")
                } else if servers.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Search the MCP Registry")
                            .font(.headline)
                        Text("Find MCP servers for filesystem, git, web search, and more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            Text("Found \(servers.count) servers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top)
                            
                            ForEach(servers) { server in
                                Button {
                                    Task {
                                        try? await MCPClient.shared.addServer(server)
                                        await onSave()
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(server.name)
                                                .font(.headline)
                                            Text(server.url)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(.blue)
                                    }
                                    .padding()
                                    .background(.regularMaterial)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("MCP Registry")
            .searchable(text: $searchText, prompt: "Search servers (e.g., filesystem, git)")
            .onChange(of: searchText) { _, newValue in
                Task {
                    await search(newValue)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                print("[MCP Browser] View appeared")
                Task {
                    await search("")
                }
            }
        }
    }
    
    private func search(_ query: String) async {
        print("[MCP Browser] Searching for: '\(query)'")
        isLoading = true
        errorMessage = nil
        
        do {
            let results = try await MCPClient.shared.fetchFromRegistry(
                search: query.isEmpty ? nil : query,
                limit: 50
            )
            print("[MCP Browser] Got \(results.count) servers")
            
            // Update on main actor
            await MainActor.run {
                self.servers = results
                print("[MCP Browser] Updated UI with \(self.servers.count) servers")
            }
        } catch {
            print("[MCP Browser] Error: \(error)")
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.servers = []
            }
        }
        
        await MainActor.run {
            self.isLoading = false
        }
    }
}
