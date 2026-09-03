import Foundation
import QuotioApplication
import QuotioDomain

public actor OpenCodeAgentConfigurationAdapter: AgentConfigurationRepository {
    public nonisolated let agent = CLIAgent.openCode

    private let fileStore: AgentFileStore
    private let configPath: String

    public init(fileStore: AgentFileStore) {
        self.fileStore = fileStore
        self.configPath = fileStore.path("~/.config/opencode/opencode.json")
    }

    public func inspect() async -> SavedAgentConfiguration? {
        guard let data = await fileStore.data(at: configPath),
              let json = try? OpenCodeConfigEditor.parseObject(data) else {
            return nil
        }

        let backups = await fileStore.listBackups(for: agent)
        guard let providers = json["provider"] as? [String: Any],
              let provider = providers["quotio"] as? [String: Any],
              let options = provider["options"] as? [String: Any] else {
            return SavedAgentConfiguration(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: backups
            )
        }

        let baseURL = options["baseURL"] as? String
        return SavedAgentConfiguration(
            baseURL: baseURL,
            apiKey: options["apiKey"] as? String,
            modelSlots: [:],
            isProxyConfigured: baseURL?.contains("127.0.0.1") == true
                || baseURL?.contains("localhost") == true,
            backupFiles: backups
        )
    }

    public func preview(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult {
        try validate(request)
        return await configurationResult(
            request,
            mode: .manual,
            existingData: await fileStore.data(at: configPath)
        )
    }

    public func apply(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult {
        try validate(request)
        let existingData = await fileStore.data(at: configPath)
        let result = await configurationResult(request, mode: request.mode, existingData: existingData)
        guard request.mode == .automatic,
              result.success,
              let output = result.rawConfigs.first,
              let instructions = result.instructions else { return result }

        do {
            let backups = try await fileStore.apply([
                AgentFileWrite(path: configPath, data: Data(output.content.utf8)),
            ])
            return .success(
                type: .file,
                mode: .automatic,
                configPath: configPath,
                rawConfigs: result.rawConfigs,
                instructions: instructions,
                modelsConfigured: result.modelsConfigured,
                backupPath: backups[configPath]
            )
        } catch {
            return .failure(.generateConfigFailed(details: error.localizedDescription))
        }
    }

    public func reset(mode: ConfigurationMode) async throws -> AgentConfigResult {
        guard mode == .automatic else {
            return .success(
                type: .file,
                mode: mode,
                instructions: .openCodeRemoveProxyManually,
                modelsConfigured: 0
            )
        }
        guard let existingData = await fileStore.data(at: configPath) else {
            return .success(
                type: .file,
                mode: mode,
                configPath: nil,
                instructions: .openCodeRemoveProxyManually,
                modelsConfigured: 0
            )
        }

        do {
            guard let updatedData = try OpenCodeConfigEditor.removingProviders(
                existing: existingData,
                keys: ["quotio"]
            ) else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    instructions: .openCodeNotConfigured,
                    modelsConfigured: 0
                )
            }
            _ = try await fileStore.apply([AgentFileWrite(path: configPath, data: updatedData)])
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                instructions: .openCodeProxyRemoved,
                modelsConfigured: 0
            )
        } catch {
            return .failure(.updateConfigFailed(details: error.localizedDescription))
        }
    }

    public func listBackups() async -> [AgentBackupFile] {
        await fileStore.listBackups(for: agent)
    }

    public func restore(_ backup: AgentBackupFile) async throws {
        guard backup.agent == agent else {
            throw AgentConfigurationServiceError.adapterMismatch(expected: agent, actual: backup.agent)
        }
        try await fileStore.restore(backup)
    }

    private func validate(_ request: AgentConfigurationRequest) throws {
        guard request.configuration.agent == agent else {
            throw AgentConfigurationServiceError.adapterMismatch(expected: agent, actual: request.configuration.agent)
        }
        try request.configuration.validate()
    }

    private func configurationResult(
        _ request: AgentConfigurationRequest,
        mode: ConfigurationMode,
        existingData: Data?
    ) async -> AgentConfigResult {
        let config = request.configuration
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        let models = request.availableModels.isEmpty ? AvailableModel.allModels : request.availableModels
        let modelConfigs = Dictionary(uniqueKeysWithValues: models.map {
            ($0.name, Self.modelConfiguration(for: $0.name))
        })
        let provider: [String: Any] = [
            "models": modelConfigs,
            "name": "Quotio",
            "npm": "@ai-sdk/anthropic",
            "options": [
                "apiKey": config.apiKey,
                "baseURL": "\(baseURL)/v1",
                "litellmProxy": true,
            ],
        ]

        do {
            let data: Data
            do {
                data = try OpenCodeConfigEditor.merging(
                    existing: existingData,
                    providers: ["quotio": provider]
                )
            } catch let error as OpenCodeConfigError {
                guard mode == .manual else {
                    let issue: OpenCodeConfigIssue
                    switch error {
                    case .notUTF8:
                        issue = .notUTF8
                    case .unterminatedBlockComment:
                        issue = .unterminatedBlockComment
                    case .unterminatedString:
                        issue = .unterminatedString
                    case .invalidSyntax(let line, let column):
                        issue = .invalidSyntax(line: line, column: column)
                    case .rootNotObject:
                        issue = .rootNotObject
                    case .duplicateKey(let key):
                        issue = .duplicateKey(key)
                    case .providerNotObject:
                        issue = .providerNotObject
                    case .verificationFailed:
                        issue = .verificationFailed
                    }
                    return .failure(.openCodeConfigInvalid(
                        path: configPath,
                        issue: issue
                    ))
                }
                data = try OpenCodeConfigEditor.merging(existing: nil, providers: ["quotio": provider])
            } catch {
                guard mode == .manual else {
                    return .failure(.generateConfigFailed(details: error.localizedDescription))
                }
                data = try OpenCodeConfigEditor.merging(existing: nil, providers: ["quotio": provider])
            }

            let rawConfigs = [RawConfigOutput(
                format: .json,
                content: String(decoding: data, as: UTF8.self),
                filename: "opencode.json",
                targetPath: configPath,
                instructions: .openCodeMergeProvider
            )]
            let instructions: AgentConfigurationInstruction = mode == .automatic
                ? .openCodeConfigured(model: models.first?.name ?? "model")
                : .openCodeMergeManualConfig
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                rawConfigs: rawConfigs,
                instructions: instructions,
                modelsConfigured: modelConfigs.count
            )
        } catch {
            return .failure(.generateConfigFailed(details: error.localizedDescription))
        }
    }

    private nonisolated static func modelConfiguration(for modelName: String) -> [String: Any] {
        var config: [String: Any] = [
            "name": modelName.split(separator: "-").map(\.capitalized).joined(separator: " "),
        ]
        if modelName.contains("claude") {
            addVision(to: &config, context: 200_000, output: 64_000)
        } else if modelName.contains("gemini") {
            addVision(to: &config, context: 1_048_576, output: 65_536)
        } else if modelName.contains("gpt") {
            addVision(to: &config, context: 400_000, output: 32_768)
        } else if modelName.contains("qwen") && modelName.contains("vl") {
            addVision(to: &config, context: 128_000, output: 16_384)
        } else if modelName.lowercased().contains("minimax") {
            config["limit"] = ["context": 1_000_000, "output": 16_384]
            config["attachment"] = true
            config["modalities"] = ["input": ["text", "image", "video"], "output": ["text"]]
        } else {
            config["limit"] = ["context": 128_000, "output": 16_384]
            config["attachment"] = false
            config["modalities"] = ["input": ["text"], "output": ["text"]]
        }

        if modelName.contains("thinking") {
            config["reasoning"] = true
            config["options"] = ["thinking": ["type": "enabled", "budgetTokens": 10_000]]
        } else if modelName.contains("codex") || modelName.hasPrefix("gpt-5")
                    || modelName.hasPrefix("o1") || modelName.hasPrefix("o3") {
            config["reasoning"] = true
            let effort = modelName.contains("max") ? "high" : modelName.contains("mini") ? "low" : "medium"
            config["options"] = ["reasoning": ["effort": effort]]
        }
        return config
    }

    private nonisolated static func addVision(
        to config: inout [String: Any],
        context: Int,
        output: Int
    ) {
        config["limit"] = ["context": context, "output": output]
        config["attachment"] = true
        config["modalities"] = ["input": ["text", "image"], "output": ["text"]]
    }
}
