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
    @State private var pendingSkillDeletion: Skill?
    @State private var pendingServerDeletion: MCPServer?
    
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
        .navigationTitle("skills.navigation.title".localized())
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSkill = true
                } label: {
                    Label("skills.action.addSkill".localized(), systemImage: "plus")
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
        .confirmationDialog(
            "skills.deleteSkill.confirm.title".localized(),
            isPresented: isSkillDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let skill = pendingSkillDeletion {
                Button("action.delete".localized(), role: .destructive) {
                    Task { await deleteSkill(skill) }
                    pendingSkillDeletion = nil
                }
            }

            Button("action.cancel".localized(), role: .cancel) {
                pendingSkillDeletion = nil
            }
        } message: {
            if let skill = pendingSkillDeletion {
                Text(String(format: "skills.deleteSkill.confirm.message".localized(), skill.name))
            }
        }
        .confirmationDialog(
            "skills.deleteServer.confirm.title".localized(),
            isPresented: isServerDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let server = pendingServerDeletion {
                Button("action.delete".localized(), role: .destructive) {
                    Task { await deleteServer(server) }
                    pendingServerDeletion = nil
                }
            }

            Button("action.cancel".localized(), role: .cancel) {
                pendingServerDeletion = nil
            }
        } message: {
            if let server = pendingServerDeletion {
                Text(String(format: "skills.deleteServer.confirm.message".localized(), server.name))
            }
        }
    }
    
    private var isSkillDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingSkillDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingSkillDeletion = nil
                }
            }
        )
    }

    private var isServerDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingServerDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingServerDeletion = nil
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("skills.empty.title".localized())
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("skills.empty.message".localized())
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button {
                showAddSkill = true
            } label: {
                Label("skills.empty.createFirst".localized(), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("skills.section.skills".localized())
                .font(.headline)
            
            ForEach(skills) { skill in
                SkillCard(skill: skill) {
                    selectedSkill = skill
                } onToggle: {
                    Task { await toggleSkill(skill) }
                } onDelete: {
                    pendingSkillDeletion = skill
                }
            }
        }
    }
    
    private var mcpServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("skills.section.mcpServers".localized())
                    .font(.headline)
                
                Spacer()
                
                Button {
                    showBrowseRegistry = true
                } label: {
                    Label("skills.action.browseRegistry".localized(), systemImage: "globe")
                        .font(.caption)
                }
                
                Button {
                    showAddServer = true
                } label: {
                    Label("skills.action.addServer".localized(), systemImage: "plus.circle")
                        .font(.caption)
                }
            }
            
            if mcpServers.isEmpty {
                Text("skills.empty.mcpServers".localized())
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(mcpServers) { server in
                    MCPServerRow(server: server) {
                        pendingServerDeletion = server
                    }
                }
            }
        }
    }
    
    private func loadData() async {
        isLoading = true
        await SkillsManager.shared.loadSkills()
        await MCPClient.shared.loadConfig()
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
                    Text(String(format: "skills.card.uses".localized(), skill.usageCount))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.2))
                        .cornerRadius(4)
                }
                
                Menu {
                    Button("action.edit".localized(), action: onEdit)
                    Button("skills.action.toggle".localized(), action: onToggle)
                    Button("action.delete".localized(), role: .destructive, action: onDelete)
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
                    Text(String(format: "skills.card.lastUsedBy".localized(), lastAgent))
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
                    Text("skills.card.keywords".localized())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(skill.triggers.keywords.joined(separator: ", "))
                        .font(.caption2)
                }
            }
            
            if !skill.triggers.agents.isEmpty {
                HStack {
                    Text("skills.card.agents".localized())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(skill.triggers.agents.joined(separator: ", "))
                        .font(.caption2)
                }
            }
            
            if !skill.tools.isEmpty {
                HStack {
                    Text("skills.card.tools".localized())
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
                Section("skills.editor.section.basicInfo".localized()) {
                    TextField("skills.editor.name".localized(), text: $name)
                    TextField("skills.editor.description".localized(), text: $description)
                }
                
                Section("skills.editor.section.triggers".localized()) {
                    TextField("skills.editor.keywords".localized(), text: $keywords)
                        .help("skills.editor.keywords.help".localized())
                    TextField("skills.editor.files".localized(), text: $files)
                        .help("skills.editor.files.help".localized())
                    TextField("skills.editor.agents".localized(), text: $agents)
                        .help("skills.editor.agents.help".localized())
                }
                
                Section("skills.editor.section.instructions".localized()) {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 150)
                }
                
                Section("skills.editor.section.mcpTools".localized()) {
                    TextField("skills.editor.tools".localized(), text: $tools)
                        .help("skills.editor.tools.help".localized())
                }
            }
            .navigationTitle(skill == nil ? "skills.editor.newTitle".localized() : "skills.editor.editTitle".localized())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel".localized()) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save".localized()) {
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
                TextField("skills.editor.name".localized(), text: $name)
                
                Picker("skills.serverSheet.type".localized(), selection: $serverType) {
                    Text("skills.serverSheet.http".localized()).tag(MCPServer.MCPServerType.http)
                    Text("skills.serverSheet.stdio".localized()).tag(MCPServer.MCPServerType.stdio)
                }
                
                TextField("skills.serverSheet.url".localized(), text: $url)
            }
            .navigationTitle("skills.serverSheet.title".localized())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel".localized()) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.create".localized()) {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
    
    private func save() async {
        let server = MCPServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            type: serverType
        )
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
                        Text("skills.registry.errorTitle".localized())
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("action.retry".localized()) {
                            Task { await search(searchText) }
                        }
                    }
                    .padding()
                } else if isLoading {
                    ProgressView("skills.registry.searching".localized())
                } else if servers.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("skills.registry.emptyTitle".localized())
                            .font(.headline)
                        Text("skills.registry.emptyMessage".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            Text(String(format: "skills.registry.foundServers".localized(), servers.count))
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
            .navigationTitle("skills.registry.title".localized())
            .searchable(text: $searchText, prompt: "skills.registry.searchPrompt".localized())
            .onChange(of: searchText) { _, newValue in
                Task {
                    await search(newValue)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.close".localized()) { dismiss() }
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
