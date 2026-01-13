import {
	chmodSync,
	copyFileSync,
	existsSync,
	mkdirSync,
	readFileSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import type { CLIAgent, CLIAgentId } from "./types";
import { CLI_AGENTS, expandPath } from "./types";

export type ConfigurationMode = "automatic" | "manual";
export type ConfigStorageOption = "json" | "shell" | "both";

export interface AgentConfiguration {
	agent: CLIAgent;
	proxyURL: string;
	apiKey: string;
	useOAuth?: boolean;
	modelSlots?: {
		opus?: string;
		sonnet?: string;
		haiku?: string;
	};
}

export interface RawConfigOutput {
	format: "shell" | "toml" | "json" | "yaml";
	content: string;
	filename?: string;
	targetPath?: string;
	instructions: string;
}

export interface AgentConfigResult {
	success: boolean;
	configType: "env" | "file" | "both";
	mode: ConfigurationMode;
	configPath?: string;
	authPath?: string;
	shellConfig?: string;
	rawConfigs: RawConfigOutput[];
	instructions: string;
	modelsConfigured: number;
	error?: string;
	backupPath?: string;
}

class AgentConfigurationServiceImpl {
	generateConfiguration(
		agentId: CLIAgentId,
		config: AgentConfiguration,
		mode: ConfigurationMode,
		storageOption: ConfigStorageOption = "json",
	): AgentConfigResult {
		const agent = CLI_AGENTS[agentId];

		switch (agentId) {
			case "claude-code":
				return this.generateClaudeCodeConfig(config, mode, storageOption);
			case "codex":
				return this.generateCodexConfig(config, mode);
			case "gemini-cli":
				return this.generateGeminiCLIConfig(config, mode);
			case "amp":
				return this.generateAmpConfig(config, mode);
			case "opencode":
				return this.generateOpenCodeConfig(config, mode);
			case "factory-droid":
				return this.generateFactoryDroidConfig(config, mode);
			default:
				return {
					success: false,
					configType: "file",
					mode,
					rawConfigs: [],
					instructions: "",
					modelsConfigured: 0,
					error: `Unknown agent: ${agentId}`,
				};
		}
	}

	private generateClaudeCodeConfig(
		config: AgentConfiguration,
		mode: ConfigurationMode,
		storageOption: ConfigStorageOption,
	): AgentConfigResult {
		const home = homedir();
		const configDir = `${home}/.claude`;
		const configPath = `${configDir}/settings.json`;

		const opusModel =
			config.modelSlots?.opus ?? "gemini-claude-opus-4-5-thinking";
		const sonnetModel = config.modelSlots?.sonnet ?? "gemini-claude-sonnet-4-5";
		const haikuModel = config.modelSlots?.haiku ?? "gemini-3-flash-preview";
		const baseURL = config.proxyURL.replace(/\/v1$/, "");

		const quotioEnvConfig: Record<string, string> = {
			ANTHROPIC_BASE_URL: baseURL,
			ANTHROPIC_AUTH_TOKEN: config.apiKey,
			ANTHROPIC_DEFAULT_OPUS_MODEL: opusModel,
			ANTHROPIC_DEFAULT_SONNET_MODEL: sonnetModel,
			ANTHROPIC_DEFAULT_HAIKU_MODEL: haikuModel,
		};

		const shellExports = `# CLIProxyAPI Configuration for Claude Code
export ANTHROPIC_BASE_URL="${baseURL}"
export ANTHROPIC_AUTH_TOKEN="${config.apiKey}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${opusModel}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnetModel}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haikuModel}"`;

		try {
			let existingConfig: Record<string, unknown> = {};
			if (existsSync(configPath)) {
				try {
					existingConfig = JSON.parse(readFileSync(configPath, "utf-8"));
				} catch {
					/* invalid json, start fresh */
				}
			}

			const mergedEnv = {
				...((existingConfig.env as Record<string, string>) ?? {}),
				...quotioEnvConfig,
			};
			existingConfig.env = mergedEnv;
			existingConfig.model = opusModel;

			const jsonString = JSON.stringify(existingConfig, null, 2);

			const rawConfigs: RawConfigOutput[] = [
				{
					format: "json",
					content: jsonString,
					filename: "settings.json",
					targetPath: configPath,
					instructions: "Option 1: Save as ~/.claude/settings.json",
				},
				{
					format: "shell",
					content: shellExports,
					targetPath: "~/.zshrc or ~/.bashrc",
					instructions: "Option 2: Add to your shell profile",
				},
			];

			if (mode === "automatic") {
				let backupPath: string | undefined;
				const shouldWriteJson =
					storageOption === "json" || storageOption === "both";

				if (shouldWriteJson) {
					mkdirSync(configDir, { recursive: true });

					if (existsSync(configPath)) {
						backupPath = `${configPath}.backup.${Math.floor(Date.now() / 1000)}`;
						copyFileSync(configPath, backupPath);
					}

					writeFileSync(configPath, jsonString);
				}

				const instructions =
					storageOption === "json"
						? "Configuration saved to ~/.claude/settings.json"
						: storageOption === "shell"
							? "Shell exports ready. Add to your shell profile to complete setup."
							: "Configuration saved to ~/.claude/settings.json and shell profile updated.";

				return {
					success: true,
					configType: "both",
					mode,
					configPath: shouldWriteJson ? configPath : undefined,
					shellConfig:
						storageOption === "shell" || storageOption === "both"
							? shellExports
							: undefined,
					rawConfigs,
					instructions,
					modelsConfigured: 3,
					backupPath,
				};
			}

			return {
				success: true,
				configType: "both",
				mode,
				configPath,
				shellConfig: shellExports,
				rawConfigs,
				instructions:
					"Choose one option: save settings.json OR add shell exports to your profile:",
				modelsConfigured: 3,
			};
		} catch (error) {
			return {
				success: false,
				configType: "both",
				mode,
				rawConfigs: [],
				instructions: "",
				modelsConfigured: 0,
				error: `Failed to generate config: ${error}`,
			};
		}
	}

	private generateCodexConfig(
		config: AgentConfiguration,
		mode: ConfigurationMode,
	): AgentConfigResult {
		const home = homedir();
		const codexDir = `${home}/.codex`;
		const configPath = `${codexDir}/config.toml`;
		const authPath = `${codexDir}/auth.json`;

		const configTOML = `# CLIProxyAPI Configuration for Codex CLI
model_provider = "cliproxyapi"
model = "${config.modelSlots?.sonnet ?? "gpt-5-codex"}"
model_reasoning_effort = "high"

[model_providers.cliproxyapi]
name = "cliproxyapi"
base_url = "${config.proxyURL}"
wire_api = "responses"`;

		const authJSON = JSON.stringify({ OPENAI_API_KEY: config.apiKey }, null, 2);

		const rawConfigs: RawConfigOutput[] = [
			{
				format: "toml",
				content: configTOML,
				filename: "config.toml",
				targetPath: configPath,
				instructions: "Save this as ~/.codex/config.toml",
			},
			{
				format: "json",
				content: authJSON,
				filename: "auth.json",
				targetPath: authPath,
				instructions: "Save this as ~/.codex/auth.json",
			},
		];

		if (mode === "automatic") {
			try {
				mkdirSync(codexDir, { recursive: true });

				let backupPath: string | undefined;
				if (existsSync(configPath)) {
					backupPath = `${configPath}.backup.${Math.floor(Date.now() / 1000)}`;
					copyFileSync(configPath, backupPath);
				}

				writeFileSync(configPath, configTOML);
				writeFileSync(authPath, authJSON);
				chmodSync(authPath, 0o600);

				return {
					success: true,
					configType: "file",
					mode,
					configPath,
					authPath,
					rawConfigs,
					instructions:
						"Configuration files created. Codex CLI is now configured to use CLIProxyAPI.",
					modelsConfigured: 1,
					backupPath,
				};
			} catch (error) {
				return {
					success: false,
					configType: "file",
					mode,
					rawConfigs: [],
					instructions: "",
					modelsConfigured: 0,
					error: `Failed to write config: ${error}`,
				};
			}
		}

		return {
			success: true,
			configType: "file",
			mode,
			configPath,
			authPath,
			rawConfigs,
			instructions: "Create the files below in ~/.codex/ directory:",
			modelsConfigured: 1,
		};
	}

	private generateGeminiCLIConfig(
		config: AgentConfiguration,
		mode: ConfigurationMode,
	): AgentConfigResult {
		const baseURL = config.proxyURL.replace(/\/v1$/, "");

		const exports = config.useOAuth
			? `# CLIProxyAPI Configuration for Gemini CLI (OAuth Mode)
export CODE_ASSIST_ENDPOINT="${baseURL}"`
			: `# CLIProxyAPI Configuration for Gemini CLI (API Key Mode)
export GOOGLE_GEMINI_BASE_URL="${baseURL}"
export GEMINI_API_KEY="${config.apiKey}"`;

		const instructions = config.useOAuth
			? "Gemini CLI will use your existing OAuth authentication with the proxy endpoint."
			: "Add these environment variables to your shell profile.";

		const rawConfigs: RawConfigOutput[] = [
			{
				format: "shell",
				content: exports,
				targetPath: "~/.zshrc or ~/.bashrc",
				instructions,
			},
		];

		return {
			success: true,
			configType: "env",
			mode,
			shellConfig: exports,
			rawConfigs,
			instructions:
				mode === "automatic"
					? "Configuration added to shell profile. Restart your terminal for changes to take effect."
					: "Copy the configuration below and add it to your shell profile:",
			modelsConfigured: 0,
		};
	}

	private generateAmpConfig(
		config: AgentConfiguration,
		mode: ConfigurationMode,
	): AgentConfigResult {
		const home = homedir();
		const configDir = `${home}/.config/amp`;
		const dataDir = `${home}/.local/share/amp`;
		const settingsPath = `${configDir}/settings.json`;
		const secretsPath = `${dataDir}/secrets.json`;
		const baseURL = config.proxyURL.replace(/\/v1$/, "");

		const settingsJSON = JSON.stringify({ "amp.url": baseURL }, null, 2);
		const secretsJSON = JSON.stringify(
			{ [`apiKey@${baseURL}`]: config.apiKey },
			null,
			2,
		);
		const envExports = `# Alternative: Environment variables for Amp CLI
export AMP_URL="${baseURL}"
export AMP_API_KEY="${config.apiKey}"`;

		const rawConfigs: RawConfigOutput[] = [
			{
				format: "json",
				content: settingsJSON,
				filename: "settings.json",
				targetPath: settingsPath,
				instructions: "Save this as ~/.config/amp/settings.json",
			},
			{
				format: "json",
				content: secretsJSON,
				filename: "secrets.json",
				targetPath: secretsPath,
				instructions: "Save this as ~/.local/share/amp/secrets.json",
			},
			{
				format: "shell",
				content: envExports,
				targetPath: "~/.zshrc (alternative)",
				instructions: "Or add these environment variables instead",
			},
		];

		if (mode === "automatic") {
			try {
				mkdirSync(configDir, { recursive: true });
				mkdirSync(dataDir, { recursive: true });

				writeFileSync(settingsPath, settingsJSON);
				writeFileSync(secretsPath, secretsJSON);
				chmodSync(secretsPath, 0o600);

				return {
					success: true,
					configType: "both",
					mode,
					configPath: settingsPath,
					authPath: secretsPath,
					shellConfig: envExports,
					rawConfigs,
					instructions:
						"Configuration files created. Amp CLI is now configured to use CLIProxyAPI.",
					modelsConfigured: 1,
				};
			} catch (error) {
				return {
					success: false,
					configType: "both",
					mode,
					rawConfigs: [],
					instructions: "",
					modelsConfigured: 0,
					error: `Failed to write config: ${error}`,
				};
			}
		}

		return {
			success: true,
			configType: "both",
			mode,
			configPath: settingsPath,
			authPath: secretsPath,
			shellConfig: envExports,
			rawConfigs,
			instructions: "Create the files below or use environment variables:",
			modelsConfigured: 1,
		};
	}

	private generateOpenCodeConfig(
		config: AgentConfiguration,
		mode: ConfigurationMode,
	): AgentConfigResult {
		const home = homedir();
		const configDir = `${home}/.config/opencode`;
		const configPath = `${configDir}/opencode.json`;
		const baseURL = config.proxyURL.replace(/\/v1$/, "");

		const defaultModels = [
			"gemini-claude-opus-4-5-thinking",
			"gemini-claude-sonnet-4-5",
			"gemini-3-flash-preview",
			"gpt-5.2-codex",
		];

		const quotioModels: Record<string, unknown> = {};
		for (const modelName of defaultModels) {
			quotioModels[modelName] = this.buildOpenCodeModelConfig(modelName);
		}

		const quotioProvider = {
			models: quotioModels,
			name: "Quotio",
			npm: "@ai-sdk/anthropic",
			options: {
				apiKey: config.apiKey,
				baseURL: `${baseURL}/v1`,
			},
		};

		try {
			let existingConfig: Record<string, unknown> = {};
			if (existsSync(configPath)) {
				try {
					existingConfig = JSON.parse(readFileSync(configPath, "utf-8"));
				} catch {
					/* invalid json */
				}
			}

			if (!existingConfig.$schema) {
				existingConfig.$schema = "https://opencode.ai/config.json";
			}

			const providers =
				(existingConfig.provider as Record<string, unknown>) ?? {};
			providers.quotio = quotioProvider;
			existingConfig.provider = providers;

			const jsonString = JSON.stringify(existingConfig, null, 2);

			const rawConfigs: RawConfigOutput[] = [
				{
					format: "json",
					content: jsonString,
					filename: "opencode.json",
					targetPath: configPath,
					instructions:
						"Merge provider.quotio into ~/.config/opencode/opencode.json",
				},
			];

			if (mode === "automatic") {
				mkdirSync(configDir, { recursive: true });

				let backupPath: string | undefined;
				if (existsSync(configPath)) {
					backupPath = `${configPath}.backup.${Math.floor(Date.now() / 1000)}`;
					copyFileSync(configPath, backupPath);
				}

				writeFileSync(configPath, jsonString);

				return {
					success: true,
					configType: "file",
					mode,
					configPath,
					rawConfigs,
					instructions: `Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/${defaultModels[0]}).`,
					modelsConfigured: Object.keys(quotioModels).length,
					backupPath,
				};
			}

			return {
				success: true,
				configType: "file",
				mode,
				configPath,
				rawConfigs,
				instructions:
					"Merge provider.quotio section into your existing ~/.config/opencode/opencode.json:",
				modelsConfigured: Object.keys(quotioModels).length,
			};
		} catch (error) {
			return {
				success: false,
				configType: "file",
				mode,
				rawConfigs: [],
				instructions: "",
				modelsConfigured: 0,
				error: `Failed to generate config: ${error}`,
			};
		}
	}

	private buildOpenCodeModelConfig(modelName: string): Record<string, unknown> {
		const displayName = modelName
			.split("-")
			.map((s) => s.charAt(0).toUpperCase() + s.slice(1))
			.join(" ");

		const modelConfig: Record<string, unknown> = { name: displayName };

		if (modelName.includes("claude")) {
			modelConfig.limit = { context: 200000, output: 64000 };
		} else if (modelName.includes("gemini")) {
			modelConfig.limit = { context: 1048576, output: 65536 };
		} else if (modelName.includes("gpt")) {
			modelConfig.limit = { context: 400000, output: 32768 };
		} else {
			modelConfig.limit = { context: 128000, output: 16384 };
		}

		if (modelName.includes("thinking")) {
			modelConfig.reasoning = true;
			modelConfig.options = {
				thinking: { type: "enabled", budgetTokens: 10000 },
			};
		} else if (
			modelName.includes("codex") ||
			modelName.startsWith("gpt-5") ||
			modelName.startsWith("o1") ||
			modelName.startsWith("o3")
		) {
			modelConfig.reasoning = true;
			if (modelName.includes("max")) {
				modelConfig.options = { reasoning: { effort: "high" } };
			} else if (modelName.includes("mini")) {
				modelConfig.options = { reasoning: { effort: "low" } };
			} else {
				modelConfig.options = { reasoning: { effort: "medium" } };
			}
		}

		return modelConfig;
	}

	private generateFactoryDroidConfig(
		config: AgentConfiguration,
		mode: ConfigurationMode,
	): AgentConfigResult {
		const home = homedir();
		const configDir = `${home}/.factory`;
		const configPath = `${configDir}/config.json`;
		const openaiBaseURL = `${config.proxyURL.replace(/\/v1$/, "")}/v1`;

		const defaultModels = [
			"gemini-claude-opus-4-5-thinking",
			"gemini-claude-sonnet-4-5",
			"gemini-3-flash-preview",
			"gpt-5.2-codex",
		];

		const customModels = defaultModels.map((modelName) => ({
			model: modelName,
			model_display_name: modelName,
			base_url: openaiBaseURL,
			api_key: config.apiKey,
			provider: "openai",
		}));

		const factoryConfig = { custom_models: customModels };
		const jsonString = JSON.stringify(factoryConfig, null, 2);

		const rawConfigs: RawConfigOutput[] = [
			{
				format: "json",
				content: jsonString,
				filename: "config.json",
				targetPath: configPath,
				instructions: "Save this as ~/.factory/config.json",
			},
		];

		if (mode === "automatic") {
			try {
				mkdirSync(configDir, { recursive: true });

				let backupPath: string | undefined;
				if (existsSync(configPath)) {
					backupPath = `${configPath}.backup.${Math.floor(Date.now() / 1000)}`;
					copyFileSync(configPath, backupPath);
				}

				writeFileSync(configPath, jsonString);

				return {
					success: true,
					configType: "file",
					mode,
					configPath,
					rawConfigs,
					instructions:
						"Configuration saved. Run 'droid' or 'factory' to start using Factory Droid.",
					modelsConfigured: customModels.length,
					backupPath,
				};
			} catch (error) {
				return {
					success: false,
					configType: "file",
					mode,
					rawConfigs: [],
					instructions: "",
					modelsConfigured: 0,
					error: `Failed to write config: ${error}`,
				};
			}
		}

		return {
			success: true,
			configType: "file",
			mode,
			configPath,
			rawConfigs,
			instructions:
				"Copy the configuration below and save it as ~/.factory/config.json:",
			modelsConfigured: customModels.length,
		};
	}
}

let serviceInstance: AgentConfigurationServiceImpl | null = null;

export function getAgentConfigurationService(): AgentConfigurationServiceImpl {
	if (!serviceInstance) {
		serviceInstance = new AgentConfigurationServiceImpl();
	}
	return serviceInstance;
}

export { AgentConfigurationServiceImpl as AgentConfigurationService };
