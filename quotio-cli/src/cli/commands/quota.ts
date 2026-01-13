import { parseArgs } from "node:util";
import { isAuthReady } from "../../models/auth.ts";
import {
	type AIProvider,
	PROVIDER_METADATA,
	getQuotaOnlyProviders,
} from "../../models/index.ts";
import { ManagementAPIClient } from "../../services/management-api.ts";
import { getQuotaService } from "../../services/quota-service.ts";
import {
	type TableColumn,
	colors,
	formatJson,
	formatTable,
	logger,
} from "../../utils/index.ts";
import {
	type CLIContext,
	type CommandResult,
	registerCommand,
} from "../index.ts";

const quotaColumns: TableColumn[] = [
	{ key: "provider", header: "Provider", width: 15 },
	{ key: "account", header: "Account", width: 25 },
	{ key: "status", header: "Status", width: 10 },
];

const detailColumns: TableColumn[] = [
	{ key: "provider", header: "Provider", width: 15 },
	{ key: "account", header: "Account", width: 25 },
	{ key: "model", header: "Model", width: 20 },
	{ key: "remaining", header: "Remaining", width: 12 },
	{ key: "resetTime", header: "Reset", width: 20 },
];

async function handleQuota(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const { values, positionals } = parseArgs({
		args,
		options: {
			help: { type: "boolean", short: "h", default: false },
			local: { type: "boolean", short: "l", default: false },
			provider: { type: "string", short: "p" },
			interval: { type: "string", short: "i", default: "60" },
		},
		allowPositionals: true,
		strict: false,
	});

	const subcommand = positionals[0] ?? "list";

	if (values.help) {
		printQuotaHelp();
		return { success: true };
	}

	switch (subcommand) {
		case "list":
		case "ls":
			if (values.local) {
				return await fetchLocalQuotas(
					ctx,
					values.provider as AIProvider | undefined,
				);
			}
			return await listQuotas(ctx);
		case "fetch":
		case "refresh":
			return await fetchLocalQuotas(
				ctx,
				values.provider as AIProvider | undefined,
			);
		case "watch":
			return await watchQuotas(
				ctx,
				values.provider as AIProvider | undefined,
				values.interval as string,
			);
		default:
			logger.error(`Unknown quota subcommand: ${subcommand}`);
			printQuotaHelp();
			return { success: false, message: `Unknown subcommand: ${subcommand}` };
	}
}

function printQuotaHelp(): void {
	const supportedProviders = getQuotaOnlyProviders()
		.map((p) => PROVIDER_METADATA[p].displayName)
		.join(", ");

	const help = `
quotio quota - View provider quota information

Usage: quotio quota <subcommand> [options]

Subcommands:
  list, ls      List auth status (default, requires proxy)
  fetch         Fetch quota data directly from providers
  watch         Real-time quota monitoring (auto-refresh)

Options:
  --local, -l   Fetch quotas directly without proxy
  --provider, -p <name>  Filter by provider (claude, gemini-cli, codex, github-copilot)
  --interval, -i <sec>   Watch refresh interval in seconds (default: 60)
  --help, -h    Show this help message

Supported Providers:
  ${supportedProviders}

Examples:
  quotio quota                    # List auth status via proxy
  quotio quota --local            # Fetch all quotas directly
  quotio quota fetch              # Same as --local
  quotio quota -l -p claude       # Fetch Claude quotas only
  quotio quota watch              # Watch quotas, refresh every 60s
  quotio quota watch -i 10        # Watch quotas, refresh every 10s
`.trim();

	logger.print(help);
}

async function listQuotas(ctx: CLIContext): Promise<CommandResult> {
	const client = new ManagementAPIClient({
		baseURL: ctx.baseUrl,
		authKey: "",
	});

	try {
		const authFiles = await client.fetchAuthFiles();

		if (authFiles.length === 0) {
			logger.print(colors.dim("No authenticated providers found."));
			logger.print("\nRun 'quotio auth login <provider>' to authenticate.");
			return { success: true, data: [] };
		}

		const rows = authFiles.map((auth) => {
			const metadata = PROVIDER_METADATA[auth.provider as AIProvider];
			const displayName = metadata?.displayName ?? auth.provider;

			let statusDisplay: string;
			if (isAuthReady(auth)) {
				statusDisplay = colors.green("Active");
			} else if (auth.statusMessage?.includes("expired")) {
				statusDisplay = colors.yellow("Expired");
			} else if (auth.disabled) {
				statusDisplay = colors.dim("Disabled");
			} else {
				statusDisplay = colors.red("Invalid");
			}

			const accountDisplay = auth.email ?? auth.account ?? auth.label ?? "-";

			return {
				provider: displayName,
				account: accountDisplay,
				status: statusDisplay,
			};
		});

		if (ctx.format === "json") {
			logger.print(formatJson(authFiles));
		} else {
			logger.print(formatTable(rows, quotaColumns));
		}

		return { success: true, data: authFiles };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.warn(`Proxy not available: ${message}`);
		logger.print(
			"\nTip: Use 'quotio quota --local' to fetch quotas without proxy.",
		);
		return { success: false, message: `Failed to list quotas: ${message}` };
	}
}

async function fetchLocalQuotas(
	ctx: CLIContext,
	filterProvider?: AIProvider,
): Promise<CommandResult> {
	logger.info("Fetching quota data directly from providers...");

	const service = getQuotaService();
	const providers = filterProvider ? [filterProvider] : undefined;
	const { quotas, errors } = await service.fetchAllQuotas(providers);

	if (quotas.size === 0 && errors.length === 0) {
		logger.print(colors.dim("No authenticated accounts found."));
		logger.print("\nRun 'quotio auth login <provider>' to authenticate.");
		return { success: true, data: [] };
	}

	const rows: Array<{
		provider: string;
		account: string;
		model: string;
		remaining: string;
		resetTime: string;
	}> = [];

	for (const [key, data] of quotas) {
		const [providerStr, account] = key.split(":");
		const metadata = PROVIDER_METADATA[providerStr as AIProvider];
		const displayName = metadata?.displayName ?? providerStr;

		if (data.isForbidden) {
			rows.push({
				provider: displayName,
				account: account ?? "-",
				model: "-",
				remaining: colors.red("Expired"),
				resetTime: "-",
			});
			continue;
		}

		if (data.models.length === 0) {
			rows.push({
				provider: displayName,
				account: account ?? "-",
				model: data.planType ?? "Connected",
				remaining: colors.dim("N/A"),
				resetTime: "-",
			});
			continue;
		}

		for (const model of data.models) {
			const remainingStr = formatRemaining(model.percentage);
			const resetStr = formatResetTime(model.resetTime);

			rows.push({
				provider: displayName,
				account: account ?? "-",
				model: model.name,
				remaining: remainingStr,
				resetTime: resetStr,
			});
		}
	}

	for (const err of errors) {
		const metadata = PROVIDER_METADATA[err.provider];
		const displayName = metadata?.displayName ?? err.provider;

		rows.push({
			provider: displayName,
			account: err.account,
			model: "-",
			remaining: colors.red("Error"),
			resetTime: err.error,
		});
	}

	if (ctx.format === "json") {
		const jsonData = Array.from(quotas.entries()).map(([key, data]) => {
			const [provider, account] = key.split(":");
			return { provider, account, ...data };
		});
		logger.print(formatJson({ quotas: jsonData, errors }));
	} else {
		logger.print(formatTable(rows, detailColumns));
		logger.print(colors.dim(`\nFetched at: ${new Date().toLocaleString()}`));
	}

	return {
		success: true,
		data: { quotas: Object.fromEntries(quotas), errors },
	};
}

function formatRemaining(percentage: number): string {
	if (percentage < 0) return colors.dim("N/A");
	if (percentage >= 75) return colors.green(`${percentage.toFixed(0)}%`);
	if (percentage >= 25) return colors.yellow(`${percentage.toFixed(0)}%`);
	return colors.red(`${percentage.toFixed(0)}%`);
}

async function watchQuotas(
	ctx: CLIContext,
	filterProvider: AIProvider | undefined,
	intervalStr: string,
): Promise<CommandResult> {
	const intervalSeconds = Number.parseInt(intervalStr, 10);
	if (Number.isNaN(intervalSeconds) || intervalSeconds < 1) {
		return {
			success: false,
			message: "Invalid interval. Must be a positive number of seconds.",
		};
	}

	let running = true;
	const cleanup = () => {
		running = false;
	};
	process.on("SIGINT", cleanup);
	process.on("SIGTERM", cleanup);

	logger.info(
		`Watching quotas every ${intervalSeconds}s. Press Ctrl+C to stop.`,
	);

	while (running) {
		console.clear();
		logger.print(colors.bold("📊 Quota Watch Mode"));
		logger.print(
			colors.dim(`Refreshing every ${intervalSeconds}s | Ctrl+C to stop\n`),
		);

		await fetchLocalQuotas(ctx, filterProvider);

		if (!running) break;
		await Bun.sleep(intervalSeconds * 1000);
	}

	process.removeListener("SIGINT", cleanup);
	process.removeListener("SIGTERM", cleanup);

	logger.print(`\n${colors.dim("Watch mode stopped.")}`);
	return { success: true };
}

function formatResetTime(resetTime: string): string {
	if (!resetTime) return "-";
	try {
		const date = new Date(resetTime);
		const now = new Date();
		const diffMs = date.getTime() - now.getTime();

		if (diffMs < 0) return colors.dim("Expired");

		const hours = Math.floor(diffMs / (1000 * 60 * 60));
		const mins = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60));

		if (hours > 24) {
			const days = Math.floor(hours / 24);
			return `${days}d ${hours % 24}h`;
		}
		return `${hours}h ${mins}m`;
	} catch {
		return resetTime;
	}
}

registerCommand("quota", handleQuota);

export { handleQuota };
