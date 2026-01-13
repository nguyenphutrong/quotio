import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { getProxyLogDir } from "../../../services/proxy-binary/constants.ts";
import { colors, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function proxyLogs(
	lines: number,
	follow: boolean,
	ctx: CLIContext,
): Promise<CommandResult> {
	const logDir = getProxyLogDir();

	try {
		await stat(logDir);
	} catch {
		logger.print(colors.dim("No log directory found."));
		logger.print(`\nExpected at: ${logDir}`);
		logger.print("Start the proxy first: quotio proxy start");
		return { success: true, data: { logs: [] } };
	}

	const logFile = await findLatestLogFile(logDir);
	if (!logFile) {
		logger.print(colors.dim("No log files found."));
		logger.print(`\nLog directory: ${logDir}`);
		return { success: true, data: { logs: [] } };
	}

	const logPath = join(logDir, logFile);

	if (follow) {
		return await tailLogs(logPath, lines, ctx);
	}

	return await showLogs(logPath, lines, ctx);
}

async function findLatestLogFile(logDir: string): Promise<string | null> {
	try {
		const files = await readdir(logDir);
		const logFiles = files.filter(
			(f) => f.endsWith(".log") || f.endsWith(".txt"),
		);

		if (logFiles.length === 0) return null;

		let latestFile: string | null = logFiles[0] ?? null;
		let latestTime = 0;

		for (const file of logFiles) {
			try {
				const fileStat = await stat(join(logDir, file));
				if (fileStat.mtimeMs > latestTime) {
					latestTime = fileStat.mtimeMs;
					latestFile = file;
				}
			} catch {
				// intentionally empty - skip files that can't be stat'd
			}
		}

		return latestFile;
	} catch {
		return null;
	}
}

async function showLogs(
	logPath: string,
	lines: number,
	ctx: CLIContext,
): Promise<CommandResult> {
	try {
		const file = Bun.file(logPath);
		const content = await file.text();
		const allLines = content.split("\n");

		const outputLines = lines > 0 ? allLines.slice(-lines) : allLines;
		const output = outputLines.join("\n").trim();

		if (!output) {
			logger.print(colors.dim("Log file is empty."));
			return { success: true, data: { logs: [] } };
		}

		if (ctx.format === "json") {
			logger.print(
				JSON.stringify({ logPath, lines: outputLines.filter(Boolean) }),
			);
		} else {
			logger.print(colors.dim(`Log file: ${logPath}`));
			logger.print(colors.dim(`Showing last ${lines} lines:\n`));
			logger.print(output);
		}

		return { success: true, data: { logPath, lines: outputLines } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Failed to read logs: ${message}` };
	}
}

async function tailLogs(
	logPath: string,
	initialLines: number,
	_ctx: CLIContext,
): Promise<CommandResult> {
	let running = true;
	const cleanup = () => {
		running = false;
	};
	process.on("SIGINT", cleanup);
	process.on("SIGTERM", cleanup);

	logger.print(colors.dim(`Tailing: ${logPath}`));
	logger.print(colors.dim("Press Ctrl+C to stop\n"));

	let lastSize = 0;

	try {
		const file = Bun.file(logPath);
		const initialContent = await file.text();
		const initialAllLines = initialContent.split("\n");
		const initialOutput = initialAllLines
			.slice(-initialLines)
			.join("\n")
			.trim();

		if (initialOutput) {
			logger.print(initialOutput);
		}

		lastSize = initialContent.length;
	} catch {
		// intentionally empty - file might not exist yet
	}

	while (running) {
		await Bun.sleep(1000);

		try {
			const file = Bun.file(logPath);
			const currentSize = file.size;

			if (currentSize > lastSize) {
				const content = await file.text();
				const newContent = content.slice(lastSize);
				if (newContent.trim()) {
					process.stdout.write(newContent);
				}
				lastSize = content.length;
			} else if (currentSize < lastSize) {
				lastSize = 0;
				logger.print(colors.dim("\n--- Log file rotated ---\n"));
			}
		} catch {
			// intentionally empty - file temporarily unavailable
		}
	}

	process.removeListener("SIGINT", cleanup);
	process.removeListener("SIGTERM", cleanup);

	logger.print(`\n${colors.dim("Log tailing stopped.")}`);
	return { success: true };
}
