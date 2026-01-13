import { getBinaryInfo } from "../../../services/proxy-binary/index.ts";
import {
	getProcessState,
	isProxyRunning,
	startProxy,
} from "../../../services/proxy-process/index.ts";
import { colors, formatJson, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function proxyStart(
	port: number,
	ctx: CLIContext,
): Promise<CommandResult> {
	try {
		const binaryInfo = await getBinaryInfo();
		if (!binaryInfo.exists) {
			logger.error("Proxy binary not found. Run 'quotio proxy install' first.");
			return { success: false, message: "Binary not installed" };
		}

		const running = await isProxyRunning();
		if (running) {
			const state = getProcessState();
			if (ctx.format === "json") {
				logger.print(formatJson({ status: "already_running", ...state }));
			} else {
				logger.print(
					`${colors.yellow("Proxy is already running")} on port ${state.port}`,
				);
			}
			return { success: true, data: { status: "already_running", ...state } };
		}

		logger.print(`Starting proxy on port ${port}...`);
		await startProxy(port);

		const state = getProcessState();
		if (ctx.format === "json") {
			logger.print(formatJson({ status: "started", ...state }));
		} else {
			logger.print(`${colors.green("✓")} Proxy started successfully`);
			logger.print(`  PID: ${state.pid}`);
			logger.print(`  Port: ${state.port}`);
			logger.print(`  URL: http://localhost:${state.port}`);
		}

		return { success: true, data: { status: "started", ...state } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.error(`Failed to start proxy: ${message}`);
		return { success: false, message };
	}
}
