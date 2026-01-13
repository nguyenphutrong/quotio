import { sendCommand } from "../../ipc/client.ts";
import {
	getDaemonStatus,
	startDaemon,
	stopDaemon,
} from "../../services/daemon/index.ts";
import { logger } from "../../utils/index.ts";
import type { CLIContext, CommandResult } from "../index.ts";
import { registerCommand } from "../index.ts";

function printHelp(): void {
	const help = `
quotio daemon - Manage the quotio-cli daemon process

Usage: quotio daemon <command> [options]

Commands:
  start     Start the daemon in the background
  stop      Stop the running daemon
  status    Show daemon status
  restart   Restart the daemon

Options:
  --foreground, -f    Run in foreground (start only)
  --help, -h          Show this help message
`.trim();

	logger.print(help);
}

async function handleStart(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const foreground = args.includes("--foreground") || args.includes("-f");

	const status = await getDaemonStatus();
	if (status.running) {
		return {
			success: false,
			message: `Daemon is already running with PID ${status.pid}`,
		};
	}

	if (foreground) {
		logger.info("Starting daemon in foreground mode...");
		await startDaemon({ foreground: true });
		return { success: true };
	}

	const currentScript = process.argv[1] ?? "quotio";
	const child = Bun.spawn(
		[process.execPath, currentScript, "daemon", "start", "--foreground"],
		{
			stdout: "ignore",
			stderr: "ignore",
			stdin: "ignore",
			env: { ...process.env, QUOTIO_DAEMON: "1" },
		},
	);

	child.unref();

	await Bun.sleep(500);

	const newStatus = await getDaemonStatus();
	if (newStatus.running) {
		logger.info(`Daemon started with PID ${newStatus.pid}`);
		return { success: true };
	}

	return { success: false, message: "Failed to start daemon" };
}

async function handleStop(
	_args: string[],
	_ctx: CLIContext,
): Promise<CommandResult> {
	const status = await getDaemonStatus();
	if (!status.running) {
		logger.info("Daemon is not running");
		return { success: true };
	}

	// Try graceful shutdown via IPC first
	let shutdownViaIpc = false;
	try {
		await sendCommand("daemon.shutdown", { graceful: true });
		shutdownViaIpc = true;
	} catch {
		// IPC failed, will fall back to signal-based stop
	}

	await Bun.sleep(500);

	// Only call stopDaemon if IPC shutdown failed (it handles the PID file cleanup)
	if (!shutdownViaIpc) {
		await stopDaemon();
	}

	logger.info("Daemon stopped");
	return { success: true };
}

async function handleStatus(
	_args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const localStatus = await getDaemonStatus();

	if (!localStatus.running) {
		if (ctx.format === "json") {
			logger.print(JSON.stringify({ running: false }, null, 2));
		} else {
			logger.print("Daemon is not running");
		}
		return { success: true };
	}

	try {
		const remoteStatus = await sendCommand("daemon.status", {});

		if (ctx.format === "json") {
			logger.print(JSON.stringify(remoteStatus, null, 2));
		} else {
			const uptimeSeconds = Math.floor(remoteStatus.uptime / 1000);
			const uptimeMinutes = Math.floor(uptimeSeconds / 60);
			const uptimeHours = Math.floor(uptimeMinutes / 60);

			let uptimeStr: string;
			if (uptimeHours > 0) {
				uptimeStr = `${uptimeHours}h ${uptimeMinutes % 60}m`;
			} else if (uptimeMinutes > 0) {
				uptimeStr = `${uptimeMinutes}m ${uptimeSeconds % 60}s`;
			} else {
				uptimeStr = `${uptimeSeconds}s`;
			}

			const proxyStatus = remoteStatus.proxyRunning
				? `Running on port ${remoteStatus.proxyPort}`
				: "Stopped";

			const lines = [
				"Status:  Running",
				`PID:     ${remoteStatus.pid}`,
				`Uptime:  ${uptimeStr}`,
				`Version: ${remoteStatus.version}`,
				`Socket:  ${localStatus.socketPath}`,
				`Proxy:   ${proxyStatus}`,
			];

			logger.print(lines.join("\n"));
		}

		return { success: true };
	} catch (error) {
		if (ctx.format === "json") {
			logger.print(
				JSON.stringify(
					{ running: true, pid: localStatus.pid, error: "Could not connect" },
					null,
					2,
				),
			);
		} else {
			logger.print(
				`Daemon running (PID ${localStatus.pid}) but not responding`,
			);
		}
		return { success: true };
	}
}

async function handleRestart(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	await handleStop(args, ctx);
	await Bun.sleep(500);
	return handleStart(
		args.filter((a) => a !== "--foreground" && a !== "-f"),
		ctx,
	);
}

async function daemonCommand(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
		printHelp();
		return { success: true };
	}

	const subcommand = args[0];
	const subArgs = args.slice(1);

	switch (subcommand) {
		case "start":
			return handleStart(subArgs, ctx);
		case "stop":
			return handleStop(subArgs, ctx);
		case "status":
			return handleStatus(subArgs, ctx);
		case "restart":
			return handleRestart(subArgs, ctx);
		default:
			logger.error(`Unknown subcommand: ${subcommand}`);
			printHelp();
			return { success: false };
	}
}

registerCommand("daemon", daemonCommand);

export { daemonCommand };
