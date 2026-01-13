import { parseArgs } from "node:util";
import {
	ALL_CLI_AGENTS,
	type AgentConfiguration,
	type CLIAgentId,
	getAgentConfigurationService,
	getAgentDetectionService,
} from "../../services/agent-detection/index.ts";
import {
	type TableColumn,
	colors,
	formatTable,
	logger,
} from "../../utils/index.ts";
import {
	type CLIContext,
	type CommandResult,
	registerCommand,
} from "../index.ts";

const agentColumns: TableColumn[] = [
	{ key: "name", header: "Agent", width: 18 },
	{ key: "status", header: "Status", width: 14 },
	{ key: "version", header: "Version", width: 25 },
	{ key: "path", header: "Path", width: 40 },
];

async function handleAgent(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const { values, positionals } = parseArgs({
		args,
		options: {
			help: { type: "boolean", short: "h", default: false },
			agent: { type: "string", short: "a" },
			url: { type: "string", short: "u", default: "http://localhost:8217/v1" },
			key: { type: "string", short: "k", default: "quotio-api-key" },
			mode: { type: "string", short: "m", default: "manual" },
		},
		allowPositionals: true,
		strict: false,
	});

	const subcommand = positionals[0] ?? "list";

	if (values.help) {
		printAgentHelp();
		return { success: true };
	}

	switch (subcommand) {
		case "list":
		case "ls":
			return await listAgents(ctx);
		case "detect":
			return await detectAgents(ctx);
		case "configure":
		case "config":
			return await configureAgent(ctx, values as ConfigureOptions);
		case "test":
			return await testAgentConnection(ctx, values as ConfigureOptions);
		case "show":
			return await showAgentConfig(ctx, values as ConfigureOptions);
		default:
			logger.error(`Unknown agent subcommand: ${subcommand}`);
			printAgentHelp();
			return { success: false, message: `Unknown subcommand: ${subcommand}` };
	}
}

interface ConfigureOptions {
	agent?: string;
	url?: string;
	key?: string;
	mode?: string;
}

function printAgentHelp(): void {
	const help = `
quotio agent - CLI agent configuration

Usage: quotio agent <subcommand> [options]

Subcommands:
  list, ls           List supported agents
  detect             Detect installed agents
  configure, config  Generate configuration for an agent
  test               Test proxy connection for an agent
  show               Show current configuration for an agent

Options:
  --help, -h         Show this help message
  --agent, -a        Agent to configure/test/show (required for most commands)
  --url, -u          Proxy URL (default: http://localhost:8217/v1)
  --key, -k          API key (default: quotio-api-key)
  --mode, -m         Mode: automatic or manual (default: manual)

Agents:
  claude-code        Claude Code (Anthropic)
  codex              Codex CLI (OpenAI)
  gemini-cli         Gemini CLI (Google)
  amp                Amp CLI (Sourcegraph)
  opencode           OpenCode
  factory-droid      Factory Droid

Examples:
  quotio agent list
  quotio agent detect
  quotio agent configure --agent claude-code --mode manual
  quotio agent config -a opencode -u http://localhost:8217/v1 -k mykey
  quotio agent test --agent claude-code
  quotio agent test -a gemini-cli -u http://localhost:9000/v1
  quotio agent show --agent claude-code
`.trim();

	logger.print(help);
}

async function listAgents(ctx: CLIContext): Promise<CommandResult> {
	const agents = ALL_CLI_AGENTS.map((agent) => ({
		id: agent.id,
		name: agent.displayName,
		description: agent.description,
		configType: agent.configType,
		binaryNames: agent.binaryNames,
	}));

	if (ctx.format === "json") {
		logger.print(JSON.stringify(agents, null, 2));
	} else {
		logger.print(colors.bold("Supported CLI Agents:\n"));
		for (const agent of agents) {
			logger.print(
				`  ${colors.cyan(agent.name)} ${colors.dim(`(${agent.id})`)}`,
			);
			logger.print(`    ${colors.dim(agent.description)}`);
			logger.print(
				`    ${colors.dim(`Binaries: ${agent.binaryNames.join(", ")}`)}`,
			);
			logger.print("");
		}
	}

	return { success: true, data: agents };
}

async function detectAgents(ctx: CLIContext): Promise<CommandResult> {
	const detectionService = getAgentDetectionService();
	const statuses = await detectionService.detectAllAgents();

	const results = statuses.map((status) => ({
		name: status.agent.displayName,
		status: formatStatus(status.installed, status.configured),
		version: status.version ?? "-",
		path: status.binaryPath ?? "-",
		configured: status.configured,
		installed: status.installed,
	}));

	if (ctx.format === "json") {
		logger.print(JSON.stringify(results, null, 2));
	} else {
		logger.print(colors.bold("Agent Detection Results:\n"));
		logger.print(formatTable(results, agentColumns));

		const installed = results.filter((r) => r.installed).length;
		const configured = results.filter((r) => r.configured).length;
		logger.print(
			`\n${colors.dim(`Found: ${installed}/${results.length} installed, ${configured} configured`)}`,
		);
	}

	return { success: true, data: results };
}

function formatStatus(installed: boolean, configured: boolean): string {
	if (!installed) {
		return colors.dim("Not found");
	}
	if (configured) {
		return colors.green("Configured");
	}
	return colors.yellow("Installed");
}

async function configureAgent(
	ctx: CLIContext,
	options: ConfigureOptions,
): Promise<CommandResult> {
	if (!options.agent) {
		logger.error("Agent is required. Use --agent or -a to specify.");
		logger.print(
			`\nAvailable agents: ${ALL_CLI_AGENTS.map((a) => a.id).join(", ")}`,
		);
		return { success: false, message: "Agent is required" };
	}

	const agentId = options.agent as CLIAgentId;
	const agent = ALL_CLI_AGENTS.find((a) => a.id === agentId);

	if (!agent) {
		logger.error(`Unknown agent: ${agentId}`);
		logger.print(
			`\nAvailable agents: ${ALL_CLI_AGENTS.map((a) => a.id).join(", ")}`,
		);
		return { success: false, message: `Unknown agent: ${agentId}` };
	}

	const mode = options.mode === "automatic" ? "automatic" : "manual";
	const configService = getAgentConfigurationService();

	const config: AgentConfiguration = {
		agent,
		proxyURL: options.url ?? "http://localhost:8217/v1",
		apiKey: options.key ?? "quotio-api-key",
	};

	const result = configService.generateConfiguration(agentId, config, mode);

	if (ctx.format === "json") {
		logger.print(JSON.stringify(result, null, 2));
		return { success: result.success, data: result };
	}

	if (!result.success) {
		logger.error(`Configuration failed: ${result.error}`);
		return { success: false, message: result.error };
	}

	logger.print(colors.bold(`\n${agent.displayName} Configuration\n`));
	logger.print(colors.dim(`Mode: ${mode}`));
	logger.print(colors.dim(`Config type: ${result.configType}`));
	logger.print("");

	if (mode === "automatic") {
		logger.print(colors.green(result.instructions));
		if (result.configPath) {
			logger.print(`\n${colors.dim("Config path:")} ${result.configPath}`);
		}
		if (result.backupPath) {
			logger.print(`${colors.dim("Backup created:")} ${result.backupPath}`);
		}
	} else {
		logger.print(colors.yellow(result.instructions));
		logger.print("");

		for (const rawConfig of result.rawConfigs) {
			logger.print(
				colors.bold(
					`\n--- ${rawConfig.filename ?? rawConfig.format.toUpperCase()} ---`,
				),
			);
			if (rawConfig.targetPath) {
				logger.print(colors.dim(`Target: ${rawConfig.targetPath}`));
			}
			logger.print(colors.dim(rawConfig.instructions));
			logger.print("");
			logger.print(rawConfig.content);
			logger.print("");
		}
	}

	return { success: true, data: result };
}

async function testAgentConnection(
	ctx: CLIContext,
	options: ConfigureOptions,
): Promise<CommandResult> {
	if (!options.agent) {
		logger.error("Agent is required. Use --agent or -a to specify.");
		logger.print(
			`\nAvailable agents: ${ALL_CLI_AGENTS.map((a) => a.id).join(", ")}`,
		);
		return { success: false, message: "Agent is required" };
	}

	const agentId = options.agent as CLIAgentId;
	const agent = ALL_CLI_AGENTS.find((a) => a.id === agentId);

	if (!agent) {
		logger.error(`Unknown agent: ${agentId}`);
		logger.print(
			`\nAvailable agents: ${ALL_CLI_AGENTS.map((a) => a.id).join(", ")}`,
		);
		return { success: false, message: `Unknown agent: ${agentId}` };
	}

	const proxyUrl = options.url ?? "http://localhost:8217/v1";
	const apiKey = options.key ?? "quotio-api-key";

	logger.print(colors.bold(`\nTesting ${agent.displayName} connection...\n`));
	logger.print(colors.dim(`Proxy URL: ${proxyUrl}`));
	logger.print(colors.dim(`API Key: ${apiKey.slice(0, 8)}...`));
	logger.print("");

	const baseUrl = proxyUrl.replace(/\/v1\/?$/, "");

	try {
		const healthResponse = await fetch(`${baseUrl}/health`, {
			method: "GET",
			signal: AbortSignal.timeout(5000),
		});

		if (!healthResponse.ok) {
			logger.print(
				`${colors.red("✗")} Proxy health check failed (HTTP ${healthResponse.status})`,
			);
			return {
				success: false,
				message: `Proxy health check failed: HTTP ${healthResponse.status}`,
			};
		}

		logger.print(`${colors.green("✓")} Proxy is reachable`);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.print(`${colors.red("✗")} Cannot connect to proxy: ${message}`);
		logger.print("\nMake sure the proxy is running: quotio proxy start");
		return { success: false, message: `Cannot connect to proxy: ${message}` };
	}

	try {
		const testResponse = await fetch(`${proxyUrl}/chat/completions`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Bearer ${apiKey}`,
			},
			body: JSON.stringify({
				model: "gpt-4",
				messages: [{ role: "user", content: "test" }],
				max_tokens: 1,
			}),
			signal: AbortSignal.timeout(10000),
		});

		if (testResponse.status === 401) {
			logger.print(
				`${colors.yellow("!")} API key rejected - check your key or add one with: quotio auth login`,
			);
			return { success: false, message: "API key rejected" };
		}

		if (testResponse.status === 503 || testResponse.status === 502) {
			logger.print(
				`${colors.yellow("!")} No active providers available - authenticate first: quotio auth login`,
			);
			return { success: false, message: "No active providers" };
		}

		logger.print(
			`${colors.green("✓")} API endpoint is accessible (HTTP ${testResponse.status})`,
		);

		if (ctx.format === "json") {
			logger.print(
				JSON.stringify(
					{
						success: true,
						agent: agentId,
						proxyUrl,
						proxyHealthy: true,
						apiEndpointStatus: testResponse.status,
					},
					null,
					2,
				),
			);
		} else {
			logger.print(`\n${colors.green("Connection test passed!")}`);
			logger.print(
				`\n${colors.dim("The agent can communicate with the proxy.")}`,
			);
		}

		return {
			success: true,
			data: { agent: agentId, proxyUrl, status: testResponse.status },
		};
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.print(`${colors.red("✗")} API request failed: ${message}`);
		return { success: false, message: `API request failed: ${message}` };
	}
}

async function showAgentConfig(
	ctx: CLIContext,
	options: ConfigureOptions,
): Promise<CommandResult> {
	if (!options.agent) {
		logger.error("Agent is required. Use --agent or -a to specify.");
		logger.print(
			`\nAvailable agents: ${ALL_CLI_AGENTS.map((a) => a.id).join(", ")}`,
		);
		return { success: false, message: "Agent is required" };
	}

	const agentId = options.agent as CLIAgentId;
	const agent = ALL_CLI_AGENTS.find((a) => a.id === agentId);

	if (!agent) {
		logger.error(`Unknown agent: ${agentId}`);
		logger.print(
			`\nAvailable agents: ${ALL_CLI_AGENTS.map((a) => a.id).join(", ")}`,
		);
		return { success: false, message: `Unknown agent: ${agentId}` };
	}

	const detectionService = getAgentDetectionService();
	const status = await detectionService.detectAgent(agent);

	const configInfo = {
		agent: {
			id: agent.id,
			name: agent.displayName,
			description: agent.description,
			configType: agent.configType,
			binaryNames: agent.binaryNames,
		},
		installation: {
			installed: status.installed,
			binaryPath: status.binaryPath ?? null,
			version: status.version ?? null,
			configured: status.configured,
		},
		configPaths: agent.configPaths,
	};

	if (ctx.format === "json") {
		logger.print(JSON.stringify(configInfo, null, 2));
		return { success: true, data: configInfo };
	}

	logger.print(colors.bold(`\n${agent.displayName}\n`));
	logger.print(colors.dim(agent.description));
	logger.print("");

	logger.print(colors.bold("Installation:"));
	if (status.installed) {
		logger.print(`  Status: ${colors.green("Installed")}`);
		if (status.binaryPath) {
			logger.print(`  Path: ${status.binaryPath}`);
		}
		if (status.version) {
			logger.print(`  Version: ${status.version}`);
		}
		logger.print(
			`  Configured: ${status.configured ? colors.green("Yes") : colors.yellow("No")}`,
		);
	} else {
		logger.print(`  Status: ${colors.dim("Not installed")}`);
		logger.print(`  Binary names: ${agent.binaryNames.join(", ")}`);
	}

	logger.print("");
	logger.print(colors.bold("Configuration:"));
	logger.print(`  Type: ${agent.configType}`);
	if (agent.configPaths.length > 0) {
		logger.print("  Config paths:");
		for (const configPath of agent.configPaths) {
			logger.print(`    - ${configPath}`);
		}
	}

	return { success: true, data: configInfo };
}

registerCommand("agent", handleAgent);

export { handleAgent };
