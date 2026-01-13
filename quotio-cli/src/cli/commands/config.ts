import { parseArgs } from "node:util";
import { ManagementAPIClient } from "../../services/management-api.ts";
import { colors, formatJson, logger } from "../../utils/index.ts";
import {
	type CLIContext,
	type CommandResult,
	registerCommand,
} from "../index.ts";

async function handleConfig(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const { values, positionals } = parseArgs({
		args,
		options: {
			help: { type: "boolean", short: "h", default: false },
		},
		allowPositionals: true,
		strict: false,
	});

	const subcommand = positionals[0] ?? "get";

	if (values.help) {
		printConfigHelp();
		return { success: true };
	}

	const client = new ManagementAPIClient({
		baseURL: ctx.baseUrl,
		authKey: "",
	});

	switch (subcommand) {
		case "get":
			return await getConfig(client, ctx, positionals.slice(1));
		case "set":
			return await setConfig(client, ctx, positionals.slice(1));
		case "list":
		case "ls":
			return await listConfig(client, ctx);
		case "reset":
			return await resetConfig(client, ctx, positionals.slice(1));
		default:
			logger.error(`Unknown config subcommand: ${subcommand}`);
			printConfigHelp();
			return { success: false, message: `Unknown subcommand: ${subcommand}` };
	}
}

function printConfigHelp(): void {
	const help = `
quotio config - Configuration management

Usage: quotio config <subcommand> [key] [value]

Subcommands:
  get [key]         Get configuration (all or specific key)
  set <key> <value> Set configuration value
  list, ls          List all configuration values
  reset [key]       Reset configuration to defaults (all or specific key)

Available keys:
  debug             Enable/disable debug mode (true/false)
  routing           Routing strategy (round-robin/fill-first)
  retry             Request retry count (number)
  max-retry-interval Maximum retry interval in seconds
  logging-to-file   Enable/disable file logging (true/false)
  proxy-url         Upstream proxy URL (set to "none" to clear)

Options:
  --help, -h    Show this help message

Examples:
  quotio config get
  quotio config list
  quotio config get debug
  quotio config set debug true
  quotio config set routing round-robin
  quotio config set retry 3
  quotio config reset           # Reset all to defaults
  quotio config reset debug     # Reset only debug
`.trim();

	logger.print(help);
}

async function getConfig(
	client: ManagementAPIClient,
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	try {
		const key = args[0];

		if (!key) {
			const config = await client.fetchConfig();
			if (ctx.format === "json") {
				logger.print(formatJson(config));
			} else {
				logger.print(`debug: ${config.debug}`);
				logger.print(`routing: ${config.routing?.strategy ?? "round-robin"}`);
				logger.print(`retry: ${config.requestRetry ?? 0}`);
				logger.print(`max-retry-interval: ${config.maxRetryInterval ?? 0}s`);
				logger.print(`logging-to-file: ${config.loggingToFile ?? false}`);
			}
			return { success: true, data: config };
		}

		let value: unknown;
		switch (key) {
			case "debug":
				value = await client.getDebug();
				break;
			case "retry":
				value = await client.getRequestRetry();
				break;
			case "max-retry-interval":
				value = await client.getMaxRetryInterval();
				break;
			case "logging-to-file":
				value = await client.getLoggingToFile();
				break;
			case "proxy-url":
				value = await client.getProxyURL();
				break;
			default:
				return { success: false, message: `Unknown config key: ${key}` };
		}

		if (ctx.format === "json") {
			logger.print(formatJson({ [key]: value }));
		} else {
			logger.print(`${key}: ${value}`);
		}

		return { success: true, data: { [key]: value } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Failed to get config: ${message}` };
	}
}

async function listConfig(
	client: ManagementAPIClient,
	ctx: CLIContext,
): Promise<CommandResult> {
	try {
		const config = await client.fetchConfig();

		if (ctx.format === "json") {
			logger.print(formatJson(config));
		} else {
			logger.print(colors.bold("Current Configuration:\n"));
			logger.print(`  ${colors.cyan("debug")}:              ${config.debug}`);
			logger.print(
				`  ${colors.cyan("routing")}:            ${config.routing?.strategy ?? "round-robin"}`,
			);
			logger.print(
				`  ${colors.cyan("retry")}:              ${config.requestRetry ?? 0}`,
			);
			logger.print(
				`  ${colors.cyan("max-retry-interval")}: ${config.maxRetryInterval ?? 0}s`,
			);
			logger.print(
				`  ${colors.cyan("logging-to-file")}:    ${config.loggingToFile ?? false}`,
			);

			try {
				const proxyUrl = await client.getProxyURL();
				logger.print(
					`  ${colors.cyan("proxy-url")}:          ${proxyUrl || colors.dim("(not set)")}`,
				);
			} catch {
				logger.print(
					`  ${colors.cyan("proxy-url")}:          ${colors.dim("(not set)")}`,
				);
			}
		}

		return { success: true, data: config };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.warn(`Cannot fetch config from proxy: ${message}`);
		logger.print("\nMake sure the proxy is running: quotio proxy start");
		return { success: false, message: `Failed to list config: ${message}` };
	}
}

async function setConfig(
	client: ManagementAPIClient,
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	const [key, value] = args;

	if (!key || value === undefined) {
		logger.error("Usage: quotio config set <key> <value>");
		return { success: false, message: "Key and value required" };
	}

	try {
		switch (key) {
			case "debug":
				await client.setDebug(value === "true" || value === "1");
				break;
			case "routing":
				if (value !== "round-robin" && value !== "fill-first") {
					return {
						success: false,
						message: "Routing must be 'round-robin' or 'fill-first'",
					};
				}
				await client.setRoutingStrategy(value);
				break;
			case "retry": {
				const retryCount = Number.parseInt(value, 10);
				if (Number.isNaN(retryCount) || retryCount < 0) {
					return {
						success: false,
						message: "Retry must be a non-negative number",
					};
				}
				await client.setRequestRetry(retryCount);
				break;
			}
			case "max-retry-interval": {
				const interval = Number.parseInt(value, 10);
				if (Number.isNaN(interval) || interval < 0) {
					return {
						success: false,
						message: "Max retry interval must be a non-negative number",
					};
				}
				await client.setMaxRetryInterval(interval);
				break;
			}
			case "logging-to-file":
				await client.setLoggingToFile(value === "true" || value === "1");
				break;
			case "proxy-url":
				if (value === "" || value === "null" || value === "none") {
					await client.deleteProxyURL();
				} else {
					await client.setProxyURL(value);
				}
				break;
			default:
				return { success: false, message: `Unknown config key: ${key}` };
		}

		logger.print(colors.green(`Set ${key} = ${value}`));
		return { success: true };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Failed to set config: ${message}` };
	}
}

const DEFAULT_CONFIG = {
	debug: false,
	routing: "round-robin" as const,
	retry: 0,
	"max-retry-interval": 60,
	"logging-to-file": false,
};

async function resetConfig(
	client: ManagementAPIClient,
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	const key = args[0];

	try {
		if (!key) {
			logger.print(colors.bold("Resetting all configuration to defaults...\n"));

			await client.setDebug(DEFAULT_CONFIG.debug);
			await client.setRoutingStrategy(DEFAULT_CONFIG.routing);
			await client.setRequestRetry(DEFAULT_CONFIG.retry);
			await client.setMaxRetryInterval(DEFAULT_CONFIG["max-retry-interval"]);
			await client.setLoggingToFile(DEFAULT_CONFIG["logging-to-file"]);

			try {
				await client.deleteProxyURL();
			} catch {
				// intentionally empty - proxy-url might not be set
			}

			if (ctx.format === "json") {
				logger.print(formatJson({ reset: "all", defaults: DEFAULT_CONFIG }));
			} else {
				logger.print(colors.green("All configuration reset to defaults:"));
				logger.print(`  debug: ${DEFAULT_CONFIG.debug}`);
				logger.print(`  routing: ${DEFAULT_CONFIG.routing}`);
				logger.print(`  retry: ${DEFAULT_CONFIG.retry}`);
				logger.print(
					`  max-retry-interval: ${DEFAULT_CONFIG["max-retry-interval"]}s`,
				);
				logger.print(`  logging-to-file: ${DEFAULT_CONFIG["logging-to-file"]}`);
				logger.print("  proxy-url: (cleared)");
			}

			return { success: true, data: { reset: "all" } };
		}

		const keyTyped = key as keyof typeof DEFAULT_CONFIG;
		if (!(key in DEFAULT_CONFIG) && key !== "proxy-url") {
			return { success: false, message: `Unknown config key: ${key}` };
		}

		switch (key) {
			case "debug":
				await client.setDebug(DEFAULT_CONFIG.debug);
				break;
			case "routing":
				await client.setRoutingStrategy(DEFAULT_CONFIG.routing);
				break;
			case "retry":
				await client.setRequestRetry(DEFAULT_CONFIG.retry);
				break;
			case "max-retry-interval":
				await client.setMaxRetryInterval(DEFAULT_CONFIG["max-retry-interval"]);
				break;
			case "logging-to-file":
				await client.setLoggingToFile(DEFAULT_CONFIG["logging-to-file"]);
				break;
			case "proxy-url":
				await client.deleteProxyURL();
				break;
		}

		const defaultValue =
			key === "proxy-url" ? "(cleared)" : DEFAULT_CONFIG[keyTyped];
		logger.print(colors.green(`Reset ${key} to default: ${defaultValue}`));
		return { success: true, data: { reset: key, value: defaultValue } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Failed to reset config: ${message}` };
	}
}

registerCommand("config", handleConfig);

export { handleConfig };
