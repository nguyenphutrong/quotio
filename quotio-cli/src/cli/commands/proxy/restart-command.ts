import { getBinaryInfo } from "../../../services/proxy-binary/index.ts";
import {
	getProcessState,
	restartProxy,
} from "../../../services/proxy-process/index.ts";
import { colors, formatJson, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function proxyRestart(
	port: number,
	ctx: CLIContext,
): Promise<CommandResult> {
	try {
		const binaryInfo = await getBinaryInfo();
		if (!binaryInfo.exists) {
			logger.error("Proxy binary not found. Run 'quotio proxy install' first.");
			return { success: false, message: "Binary not installed" };
		}

		logger.print("Restarting proxy...");
		await restartProxy(port);

		const state = getProcessState();
		if (ctx.format === "json") {
			logger.print(formatJson({ status: "restarted", ...state }));
		} else {
			logger.print(`${colors.green("✓")} Proxy restarted successfully`);
			logger.print(`  PID: ${state.pid}`);
			logger.print(`  Port: ${state.port}`);
		}

		return { success: true, data: { status: "restarted", ...state } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.error(`Failed to restart proxy: ${message}`);
		return { success: false, message };
	}
}
