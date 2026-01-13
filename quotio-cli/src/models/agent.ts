export enum CLIAgent {
	CLAUDE_CODE = "claude-code",
	CODEX_CLI = "codex",
	GEMINI_CLI = "gemini-cli",
	AMP_CLI = "amp",
	OPENCODE = "opencode",
	FACTORY_DROID = "factory-droid",
}

export enum AgentConfigType {
	ENVIRONMENT = "env",
	FILE = "file",
	BOTH = "both",
}

export enum ConfigurationMode {
	AUTOMATIC = "automatic",
	MANUAL = "manual",
}

export enum ConfigStorageOption {
	JSON_ONLY = "json",
	SHELL_ONLY = "shell",
	BOTH = "both",
}

export enum ShellType {
	ZSH = "zsh",
	BASH = "bash",
	FISH = "fish",
}

export enum ModelSlot {
	OPUS = "opus",
	SONNET = "sonnet",
	HAIKU = "haiku",
}

export interface AgentMetadata {
	id: CLIAgent;
	displayName: string;
	description: string;
	binaryNames: string[];
	configPaths: string[];
	configType: AgentConfigType;
	docsUrl: string | null;
	color: string;
	iconName: string;
}

export const AGENT_METADATA: Record<CLIAgent, AgentMetadata> = {
	[CLIAgent.CLAUDE_CODE]: {
		id: CLIAgent.CLAUDE_CODE,
		displayName: "Claude Code",
		description: "Anthropic's official CLI for Claude models",
		binaryNames: ["claude"],
		configPaths: ["~/.claude/settings.json"],
		configType: AgentConfigType.BOTH,
		docsUrl: "https://docs.anthropic.com/en/docs/claude-code",
		color: "#D97706",
		iconName: "brain.head.profile",
	},
	[CLIAgent.CODEX_CLI]: {
		id: CLIAgent.CODEX_CLI,
		displayName: "Codex CLI",
		description: "OpenAI's Codex CLI for GPT-5 models",
		binaryNames: ["codex"],
		configPaths: ["~/.codex/config.toml", "~/.codex/auth.json"],
		configType: AgentConfigType.FILE,
		docsUrl: "https://github.com/openai/codex",
		color: "#10A37F",
		iconName: "chevron.left.forwardslash.chevron.right",
	},
	[CLIAgent.GEMINI_CLI]: {
		id: CLIAgent.GEMINI_CLI,
		displayName: "Gemini CLI",
		description: "Google's Gemini CLI for Gemini models",
		binaryNames: ["gemini"],
		configPaths: [],
		configType: AgentConfigType.ENVIRONMENT,
		docsUrl: "https://github.com/google-gemini/gemini-cli",
		color: "#4285F4",
		iconName: "sparkles",
	},
	[CLIAgent.AMP_CLI]: {
		id: CLIAgent.AMP_CLI,
		displayName: "Amp CLI",
		description: "Sourcegraph's Amp coding assistant",
		binaryNames: ["amp"],
		configPaths: [
			"~/.config/amp/settings.json",
			"~/.local/share/amp/secrets.json",
		],
		configType: AgentConfigType.BOTH,
		docsUrl: "https://ampcode.com/manual",
		color: "#FF5543",
		iconName: "bolt.fill",
	},
	[CLIAgent.OPENCODE]: {
		id: CLIAgent.OPENCODE,
		displayName: "OpenCode",
		description: "The open source AI coding agent",
		binaryNames: ["opencode", "oc"],
		configPaths: ["~/.config/opencode/opencode.json"],
		configType: AgentConfigType.FILE,
		docsUrl: "https://github.com/sst/opencode",
		color: "#8B5CF6",
		iconName: "terminal",
	},
	[CLIAgent.FACTORY_DROID]: {
		id: CLIAgent.FACTORY_DROID,
		displayName: "Factory Droid",
		description: "Factory's AI coding agent",
		binaryNames: ["droid", "factory-droid", "fd"],
		configPaths: ["~/.factory/config.json"],
		configType: AgentConfigType.FILE,
		docsUrl: "https://github.com/github/github-spark",
		color: "#238636",
		iconName: "cpu",
	},
};

export interface AvailableModel {
	id: string;
	name: string;
	provider: string;
	isDefault: boolean;
}

export const DEFAULT_MODEL_SLOTS: Record<ModelSlot, AvailableModel> = {
	[ModelSlot.OPUS]: {
		id: "opus",
		name: "gemini-claude-opus-4-5-thinking",
		provider: "openai",
		isDefault: true,
	},
	[ModelSlot.SONNET]: {
		id: "sonnet",
		name: "gemini-claude-sonnet-4-5",
		provider: "openai",
		isDefault: true,
	},
	[ModelSlot.HAIKU]: {
		id: "haiku",
		name: "gemini-3-flash-preview",
		provider: "openai",
		isDefault: true,
	},
};

export interface AgentStatus {
	agent: CLIAgent;
	installed: boolean;
	configured: boolean;
	binaryPath: string | null;
	version: string | null;
	lastConfigured: Date | null;
}

export interface AgentConfiguration {
	agent: CLIAgent;
	modelSlots: Record<ModelSlot, string>;
	proxyURL: string;
	apiKey: string;
	useOAuth: boolean;
}

export interface RawConfigOutput {
	format: "shell" | "toml" | "json" | "yaml";
	content: string;
	filename: string | null;
	targetPath: string | null;
	instructions: string;
}

export interface AgentConfigResult {
	success: boolean;
	configType: AgentConfigType;
	mode: ConfigurationMode;
	configPath: string | null;
	authPath: string | null;
	shellConfig: string | null;
	rawConfigs: RawConfigOutput[];
	instructions: string;
	modelsConfigured: number;
	error: string | null;
	backupPath: string | null;
}

export interface ConnectionTestResult {
	success: boolean;
	message: string;
	latencyMs: number | null;
	modelResponded: string | null;
}

export function getAgentMetadata(agent: CLIAgent): AgentMetadata {
	return AGENT_METADATA[agent];
}

export function getShellProfilePath(shell: ShellType): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "~";
	switch (shell) {
		case ShellType.ZSH:
			return `${home}/.zshrc`;
		case ShellType.BASH:
			return `${home}/.bashrc`;
		case ShellType.FISH:
			return `${home}/.config/fish/config.fish`;
	}
}

export function getShellExportPrefix(shell: ShellType): string {
	switch (shell) {
		case ShellType.ZSH:
		case ShellType.BASH:
			return "export";
		case ShellType.FISH:
			return "set -gx";
	}
}

export function createDefaultAgentConfiguration(
	agent: CLIAgent,
	proxyURL: string,
	apiKey: string,
): AgentConfiguration {
	return {
		agent,
		proxyURL,
		apiKey,
		useOAuth: agent === CLIAgent.GEMINI_CLI,
		modelSlots: {
			[ModelSlot.OPUS]: DEFAULT_MODEL_SLOTS[ModelSlot.OPUS].name,
			[ModelSlot.SONNET]: DEFAULT_MODEL_SLOTS[ModelSlot.SONNET].name,
			[ModelSlot.HAIKU]: DEFAULT_MODEL_SLOTS[ModelSlot.HAIKU].name,
		},
	};
}

export function createAgentConfigSuccess(opts: {
	type: AgentConfigType;
	mode: ConfigurationMode;
	configPath?: string;
	authPath?: string;
	shellConfig?: string;
	rawConfigs?: RawConfigOutput[];
	instructions: string;
	modelsConfigured?: number;
	backupPath?: string;
}): AgentConfigResult {
	return {
		success: true,
		configType: opts.type,
		mode: opts.mode,
		configPath: opts.configPath ?? null,
		authPath: opts.authPath ?? null,
		shellConfig: opts.shellConfig ?? null,
		rawConfigs: opts.rawConfigs ?? [],
		instructions: opts.instructions,
		modelsConfigured: opts.modelsConfigured ?? 3,
		error: null,
		backupPath: opts.backupPath ?? null,
	};
}

export function createAgentConfigFailure(error: string): AgentConfigResult {
	return {
		success: false,
		configType: AgentConfigType.ENVIRONMENT,
		mode: ConfigurationMode.AUTOMATIC,
		configPath: null,
		authPath: null,
		shellConfig: null,
		rawConfigs: [],
		instructions: "",
		modelsConfigured: 0,
		error,
		backupPath: null,
	};
}
