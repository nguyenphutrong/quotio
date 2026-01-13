import { readdirSync } from "node:fs";
import { homedir } from "node:os";

export type CLIAgentId =
	| "claude-code"
	| "codex"
	| "gemini-cli"
	| "amp"
	| "opencode"
	| "factory-droid";

export type AgentConfigType = "env" | "file" | "both";

export interface CLIAgent {
	id: CLIAgentId;
	displayName: string;
	description: string;
	configType: AgentConfigType;
	binaryNames: string[];
	configPaths: string[];
	docsURL?: string;
}

export const CLI_AGENTS: Record<CLIAgentId, CLIAgent> = {
	"claude-code": {
		id: "claude-code",
		displayName: "Claude Code",
		description: "Anthropic's official CLI for Claude models",
		configType: "both",
		binaryNames: ["claude"],
		configPaths: ["~/.claude/settings.json"],
		docsURL: "https://docs.anthropic.com/en/docs/claude-code",
	},
	codex: {
		id: "codex",
		displayName: "Codex CLI",
		description: "OpenAI's Codex CLI for GPT-5 models",
		configType: "file",
		binaryNames: ["codex"],
		configPaths: ["~/.codex/config.toml", "~/.codex/auth.json"],
		docsURL: "https://github.com/openai/codex",
	},
	"gemini-cli": {
		id: "gemini-cli",
		displayName: "Gemini CLI",
		description: "Google's Gemini CLI for Gemini models",
		configType: "env",
		binaryNames: ["gemini"],
		configPaths: [],
		docsURL: "https://github.com/google-gemini/gemini-cli",
	},
	amp: {
		id: "amp",
		displayName: "Amp CLI",
		description: "Sourcegraph's Amp coding assistant",
		configType: "both",
		binaryNames: ["amp"],
		configPaths: [
			"~/.config/amp/settings.json",
			"~/.local/share/amp/secrets.json",
		],
		docsURL: "https://ampcode.com/manual",
	},
	opencode: {
		id: "opencode",
		displayName: "OpenCode",
		description: "The open source AI coding agent",
		configType: "file",
		binaryNames: ["opencode", "oc"],
		configPaths: ["~/.config/opencode/opencode.json"],
		docsURL: "https://github.com/sst/opencode",
	},
	"factory-droid": {
		id: "factory-droid",
		displayName: "Factory Droid",
		description: "Factory's AI coding agent",
		configType: "file",
		binaryNames: ["droid", "factory-droid", "fd"],
		configPaths: ["~/.factory/config.json"],
		docsURL: "https://github.com/github/github-spark",
	},
};

export const ALL_CLI_AGENTS = Object.values(CLI_AGENTS);

export interface AgentStatus {
	agent: CLIAgent;
	installed: boolean;
	configured: boolean;
	binaryPath?: string;
	version?: string;
	lastConfigured?: Date;
}

export const COMMON_BINARY_PATHS = [
	"/usr/local/bin",
	"/opt/homebrew/bin",
	"/usr/bin",
	"~/.local/bin",
	"~/.cargo/bin",
	"~/.bun/bin",
	"~/.deno/bin",
	"~/.npm-global/bin",
	"~/.opencode/bin",
	"~/.volta/bin",
	"~/.asdf/shims",
	"~/.local/share/mise/shims",
];

export function expandPath(path: string): string {
	return path.replace(/^~/, homedir());
}

export function getVersionManagerPaths(
	binaryName: string,
	home: string,
): string[] {
	const paths: string[] = [];

	const nvmBase = `${home}/.nvm/versions/node`;
	try {
		const versions = readdirSync(nvmBase).sort().reverse();
		for (const version of versions) {
			paths.push(`${nvmBase}/${version}/bin/${binaryName}`);
		}
	} catch {
		/* nvm not installed */
	}

	const xdgDataHome = process.env.XDG_DATA_HOME || `${home}/.local/share`;
	const fnmPaths = [
		`${xdgDataHome}/fnm/node-versions`,
		`${home}/.fnm/node-versions`,
	];

	for (const fnmBase of fnmPaths) {
		try {
			const versions = readdirSync(fnmBase);
			if (versions.length > 0) {
				for (const version of versions.sort().reverse()) {
					paths.push(`${fnmBase}/${version}/installation/bin/${binaryName}`);
				}
				break;
			}
		} catch {
			/* fnm not installed */
		}
	}

	return paths;
}
