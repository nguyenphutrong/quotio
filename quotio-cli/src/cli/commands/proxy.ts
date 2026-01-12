import { parseArgs } from "node:util";
import { registerCommand, type CLIContext, type CommandResult } from "../index.ts";
import { logger } from "../../utils/index.ts";
import {
  proxyStart,
  proxyStop,
  proxyRestart,
  proxyInstall,
  proxyUninstall,
  proxyStatus,
  healthCheck,
} from "./proxy/index.ts";

async function handleProxy(args: string[], ctx: CLIContext): Promise<CommandResult> {
  const { values, positionals } = parseArgs({
    args,
    options: {
      help: { type: "boolean", short: "h", default: false },
      port: { type: "string", short: "p" },
    },
    allowPositionals: true,
    strict: false,
  });

  const subcommand = positionals[0] ?? "status";

  if (values.help) {
    printProxyHelp();
    return { success: true };
  }

  const port = typeof values.port === "string" ? Number.parseInt(values.port, 10) : 8217;

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

Options:
  --port, -p <port>   Port to run the proxy on (default: 8217)
  --help, -h          Show this help message

Examples:
  quotio proxy                    # Show status
  quotio proxy start              # Start on default port
  quotio proxy start -p 9000      # Start on port 9000
  quotio proxy stop               # Stop the proxy
  quotio proxy restart            # Restart the proxy
  quotio proxy install            # Install the embedded binary
`.trim();

  logger.print(help);
}

registerCommand("proxy", handleProxy);

export { handleProxy };
