import { parseArgs } from "node:util";
import { logger } from "../../utils/index.ts";
import {
	type CLIContext,
	type CommandResult,
	registerCommand,
} from "../index.ts";
import {
	healthCheck,
	proxyInstall,
	proxyLogs,
	proxyRestart,
	proxyStart,
	proxyStatus,
	proxyStop,
	proxyUninstall,
} from "./proxy/index.ts";

async function handleProxy(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const { values, positionals } = parseArgs({
		args,
		options: {
			help: { type: "boolean", short: "h", default: false },
			port: { type: "string", short: "p" },
			follow: { type: "boolean", short: "f", default: false },
			lines: { type: "string", short: "n", default: "50" },
		},
		allowPositionals: true,
		strict: false,
	});

	const subcommand = positionals[0] ?? "status";

	if (values.help) {
		printProxyHelp();
		return { success: true };
	}

	const port =
		typeof values.port === "string" ? Number.parseInt(values.port, 10) : 8217;

	switch (subcommand) {
		case "start":
			return await proxyStart(port, ctx);
		case "stop":
			return await proxyStop(ctx);
		case "restart":
			return await proxyRestart(port, ctx);
		case "install":
			return await proxyInstall(ctx);
		case "uninstall":
			return await proxyUninstall(ctx);
		case "status":
			return await proxyStatus(port, ctx);
		case "health":
			return await healthCheck(port, ctx);
		case "logs": {
			const lines = Number.parseInt(values.lines as string, 10) || 50;
			return await proxyLogs(lines, values.follow as boolean, ctx);
		}
		default:
			logger.error(`Unknown proxy subcommand: ${subcommand}`);
			printProxyHelp();
			return { success: false, message: `Unknown subcommand: ${subcommand}` };
	}
}

function printProxyHelp(): void {
	const help = `
quotio proxy - Proxy server control

Usage: quotio proxy <subcommand> [options]

Subcommands:
  status        Show proxy status (default)
  health        Check if proxy is healthy
  start         Start the proxy server
  stop          Stop the proxy server
  restart       Restart the proxy server
  install       Extract and install the proxy binary
  uninstall     Remove the installed proxy binary
  logs          View proxy server logs

Options:
  --port, -p <port>   Port to run the proxy on (default: 8217)
  --follow, -f        Follow log output (tail -f mode)
  --lines, -n <num>   Number of log lines to show (default: 50)
  --help, -h          Show this help message

Examples:
  quotio proxy                    # Show status
  quotio proxy start              # Start on default port
  quotio proxy start -p 9000      # Start on port 9000
  quotio proxy stop               # Stop the proxy
  quotio proxy restart            # Restart the proxy
  quotio proxy install            # Install the embedded binary
  quotio proxy logs               # Show last 50 log lines
  quotio proxy logs -n 100        # Show last 100 log lines
  quotio proxy logs -f            # Tail logs in real-time
`.trim();

	logger.print(help);
}

registerCommand("proxy", handleProxy);

export { handleProxy };
